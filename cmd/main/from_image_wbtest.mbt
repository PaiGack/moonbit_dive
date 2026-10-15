///|
/// `CommandError` 只对断言用，不引入 `Show`：测试里读一眼就够了。
fn describe_error(error : CommandError) -> String {
  match error {
    Image(message) => "image: \{message}"
    Analysis(message) => "analysis: \{message}"
    Docker(message) => "docker: \{message}"
  }
}

///|
/// 只探测 CLI 后端的候选列表。
///
/// `default_candidates` 一定会把 `/var/run/docker.sock` 塞进去，
/// 装了真 daemon 的 CI 上就轮不到 fake docker，用例会变成「看机器装没装 docker」。
/// 这里显式钉住候选，跟 `docker_cli/probe_test.mbt` 同一个路子。
fn cli_only() -> Array[@docker_cli.BackendCandidate] {
  [@docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker)]
}

///|
/// 端到端：`--from-image` 用 fake docker 的 `save` 取归档，
/// 再走既有 `ImageSource::from_tar_bytes` 出体积报告，不新开链路。
async test "from-image wires docker_cli output into the analysis path" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit"),
  ])
  // config 要带 rootfs.diff_ids：`ImageSource::from_tar_bytes` 会校它，
  // 真 docker save 的产物从来都有，这里按真实形态造
  let archive = @docker_cli.build_docker_archive(
    [("cafe", layer)],
    config="cafe.json",
    config_json=(
      #|{ "architecture": "amd64", "os": "linux", "rootfs": { "type": "layers", "diff_ids": ["sha256:cafe"] } }
    ),
  )
  let archive_path = @docker_cli.write_temp_bytes("from-image.tar", archive)
  // 探测链路按 PATH 找的是工具名本身（`docker`），所以文件就得叫 docker
  let script = @docker_cli.fake_cat_cli(archive_path)
  let (dir, _program) = @docker_cli.write_fake_cli_named("docker", script)

  let options = Options::from_matches(
    cli().parse(argv=["example:latest", "--from-image"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  let env = { "PATH": dir }
  let source = load_source(options, env~, candidates=cli_only()) catch {
    err => fail("from-image should load: \{describe_error(err)}")
  }
  assert_eq(source.layers.length(), 1)
  // 名字标出来源，报告 / 注解能看出这不是本地 tar
  assert_eq(source.name, "example:latest (from-image)")

  // 层能直接喂给 P3：输入契约不变
  let tree = @layer_tree.FileTree::new()
  let streams : Array[BytesView] = []
  for layer in source.layers {
    streams.push(layer.raw_bytes() catch { err => fail(err.to_string()) })
  }
  let analysis = @image_analysis.analyze_layers(tree, streams) catch {
    err => fail("analysis should accept the layers: \{err}")
  }
  assert_true(analysis.final_file_bytes > 0)

  @docker_cli.remove_fake_cli_dir(dir)
  @docker_cli.remove_temp_bytes(archive_path)
}

///|
/// 无 daemon / 无 CLI：探测全失败要抛 `CommandError::Docker`，
/// 人话里带上安装提示，而不是 IO 层面的「读不到文件」。
async test "from-image without any backend reports a docker error" {
  // 给一个空目录当 PATH（里面没有任何 docker / podman / nerdctl）
  let (empty, _probe) = @docker_cli.write_fake_cli_named(
    "not-docker", "#!/bin/sh\n",
  )
  let options = Options::from_matches(
    cli().parse(argv=["nginx:latest", "--from-image"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  let env = { "PATH": empty }
  let error : CommandError = try {
    load_source(options, env~, candidates=cli_only()) |> ignore
    Image("expected an error, got a source")
  } catch {
    Docker(message) => Docker(message)
    Image(message) => Image(message)
    Analysis(message) => Analysis(message)
  }
  assert_true(error is Docker(_))
  let message = describe_error(error)
  assert_true(message.contains("no usable docker backend"))
  // 安装提示要在，不能只丢一句「命令找不到」
  assert_true(message.contains("DOCKER_CLI"))
  assert_true(message.contains("docker / podman / nerdctl"))

  @docker_cli.remove_fake_cli_dir(empty)
}

///|
/// 不给 `--from-image` 时走文件路径：给个不存在的位置参数报 Image，不是 Docker。
///
/// 这条守住「显式开关优先」：默认绝不因为位置参数长得像镜像名就去连 daemon。
async test "without from-image the input is treated as a file path" {
  let options = Options::from_matches(
    cli().parse(argv=["/definitely/not/here.tar"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  let error : CommandError = try {
    load_source(options) |> ignore
    Image("expected an error, got a source")
  } catch {
    Image(message) => Image(message)
    Docker(message) => Docker(message)
    Analysis(message) => Analysis(message)
  }
  assert_true(error is Image(_))
}

///|
/// `--verbose` 只多打探测记录，不改变「取到归档 → 分析」的结果。
///
/// 探测记录走 stderr（不混进报告），这里只验开了它之后链路照样跑通、
/// 层数不变——`eprintln` 的内容在进程内不好断言，端到端的手动验证见
/// docs/p5-docker-cli.md 的命令示例。
async test "verbose does not change the fetched result" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit"),
  ])
  let archive = @docker_cli.build_docker_archive(
    [("cafe", layer)],
    config="cafe.json",
    config_json=(
      #|{ "architecture": "amd64", "os": "linux", "rootfs": { "type": "layers", "diff_ids": ["sha256:cafe"] } }
    ),
  )
  let archive_path = @docker_cli.write_temp_bytes("verbose.tar", archive)
  let script = @docker_cli.fake_cat_cli(archive_path)
  let (dir, _program) = @docker_cli.write_fake_cli_named("docker", script)

  let options = Options::from_matches(
    cli().parse(argv=["example:latest", "--from-image", "--verbose"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  assert_true(options.verbose)
  let source = load_source(options, env={ "PATH": dir }, candidates=cli_only()) catch {
    err => fail("from-image should load: \{describe_error(err)}")
  }
  assert_eq(source.layers.length(), 1)

  @docker_cli.remove_fake_cli_dir(dir)
  @docker_cli.remove_temp_bytes(archive_path)
}
