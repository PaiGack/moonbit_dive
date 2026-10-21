///|
/// `CommandError` 只对断言用，不引入 `Show`：测试里读一眼就够了。
fn describe_error(error : CommandError) -> String {
  match error {
    Image(message) => "image: \{message}"
    Analysis(message) => "analysis: \{message}"
    Docker(message) => "docker: \{message}"
    NoLocalImage(message) => "no-local-image: \{message}"
    Registry(message) => "registry: \{message}"
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
/// 端到端：镜像引用用 fake docker 的 `save` 取归档，
/// 再走既有 `ImageSource::from_tar_bytes` 出体积报告，不新开链路。
async test "an image reference wires docker_cli output into the analysis path" {
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
  let archive_path = @docker_cli.write_temp_bytes("reference.tar", archive)
  // 探测链路按 PATH 找的是工具名本身（`docker`），所以文件就得叫 docker
  let script = @docker_cli.fake_cat_cli(archive_path)
  let (dir, _program) = @docker_cli.write_fake_cli_named("docker", script)

  let options = Options::from_matches(
    cli().parse(argv=["example:latest"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  let env = { "PATH": dir }
  let source = load_source(options, env~, candidates=cli_only()) catch {
    err => fail("the reference should load: \{describe_error(err)}")
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
/// 无 daemon / 无 CLI：探测全失败，`--no-pull` 下直接报 `CommandError::Docker`，
/// 人话里带上安装提示，而不是 IO 层面的「读不到文件」，也不会偷偷去连 registry。
///
/// 不给 `--no-pull` 的那一半见下一条用例：那时要回退到 registry（issue #109）。
async test "a reference without any backend reports a docker error under --no-pull" {
  // 给一个空目录当 PATH（里面没有任何 docker / podman / nerdctl）
  let (empty, _probe) = @docker_cli.write_fake_cli_named(
    "not-docker", "#!/bin/sh\n",
  )
  let options = Options::from_matches(
    cli().parse(argv=["nginx:latest", "--no-pull"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  assert_true(options.no_pull)
  let error : CommandError = try {
    load_source(options, env={ "PATH": empty }, candidates=cli_only()) |> ignore
    Image("expected an error, got a source")
  } catch {
    Docker(message) => Docker(message)
    NoLocalImage(message) => NoLocalImage(message)
    Image(message) => Image(message)
    Analysis(message) => Analysis(message)
    Registry(message) => Registry(message)
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
/// 没有 docker 就自己连 registry：issue #109 的主要诉求。
///
/// 这里用一个必然连不上的 registry（`127.0.0.1:1` 上没人监听）来证明
/// **回退真的发生了**：报出来的错变成 registry 的，不再是 docker 的。
/// 「回退之后能拉成功」由 `registry_cli` 自己的用例保证，不必在这叠网络。
async test "a reference falls back to the registry when there is no docker" {
  let (empty, _probe) = @docker_cli.write_fake_cli_named(
    "not-docker", "#!/bin/sh\n",
  )
  let options = Options::from_matches(
    cli().parse(argv=["127.0.0.1:1/demo:latest", "--timeout", "1"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  assert_false(options.no_pull)
  let error : CommandError = try {
    load_source(options, env={ "PATH": empty }, candidates=cli_only()) |> ignore
    Image("expected an error, got a source")
  } catch {
    Docker(message) => Docker(message)
    NoLocalImage(message) => NoLocalImage(message)
    Image(message) => Image(message)
    Analysis(message) => Analysis(message)
    Registry(message) => Registry(message)
  }
  // 报的必须是 registry 的错：回退发生了
  assert_true(error is Registry(_))
  @docker_cli.remove_fake_cli_dir(empty)
}

///|
/// 有 docker 但取不到归档时**不**回退：那是「这条路推不动」，不是「没有 docker」。
///
/// 拿一次注定失败的 registry 拉取盖住真正的错，是这次改动最该防的回归。
async test "a reference does not fall back when a docker backend was probed" {
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
  let archive_path = @docker_cli.write_temp_bytes("no-fallback.tar", archive)
  let dir = @async_fs.tmpdir(prefix="dive-from-image-no-fallback-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  // inspect 说本地有，save 却非零退出：后端是活的，只是这个镜像导不出来
  let script = @docker_cli.fake_recording_cli(
    log,
    archive_path,
    "[{\"Id\":\"sha256:cafe\"}]",
    save_code=1,
  )
  let (bin, _program) = @docker_cli.write_fake_cli_named("docker", script)

  let options = Options::from_matches(
    cli().parse(argv=["example:latest"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  let error : CommandError = try {
    load_source(options, env={ "PATH": bin }, candidates=cli_only()) |> ignore
    Image("expected an error, got a source")
  } catch {
    Docker(message) => Docker(message)
    NoLocalImage(message) => NoLocalImage(message)
    Image(message) => Image(message)
    Analysis(message) => Analysis(message)
    Registry(message) => Registry(message)
  }
  assert_true(error is Docker(_))

  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_temp_bytes(archive_path)
  @docker_cli.remove_fake_cli_dir(dir)
}

///|
/// 不存在的路径 + 长得像镜像名 → 走镜像通路，而不是报「读不到文件」。
///
/// 这是 issue #124 反转的那条：以前「不给 `--from-image` 就一定当文件」，
/// 于是 `dive nginx:latest` 报的是 `cannot read nginx:latest: No such file or directory`。
/// 现在位置参数自己说它是什么，判定在 `ImageSource::load` 之前做完。
async test "a missing path is treated as an image reference, not a file" {
  assert_eq(kind_of_input("/definitely/not/here.tar"), Reference)
  let options = Options::from_matches(
    cli().parse(argv=["/definitely/not/here.tar", "--no-pull"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  // 给一个空目录当 PATH：探测不到任何后端，`--no-pull` 下不许回退 registry。
  // 只要报的**不是** `Image("cannot read ...")`，就说明没走文件那条路。
  let (empty, _probe) = @docker_cli.write_fake_cli_named(
    "not-docker", "#!/bin/sh\n",
  )
  let error : CommandError = try {
    load_source(options, env={ "PATH": empty }, candidates=cli_only()) |> ignore
    Image("expected an error, got a source")
  } catch {
    Image(message) => Image(message)
    Docker(message) => Docker(message)
    NoLocalImage(message) => NoLocalImage(message)
    Analysis(message) => Analysis(message)
    Registry(message) => Registry(message)
  }
  assert_true(error is Docker(_))
  assert_true(describe_error(error).contains("no usable docker backend"))
  @docker_cli.remove_fake_cli_dir(empty)
}

///|
/// 存在的路径一步都不碰网络：哪怕 PATH 上一个 docker 都没有。
///
/// 这条守住「本地文件优先」：判定只看本地文件系统，不看能不能连 daemon。
async test "an existing path never touches docker" {
  // 仓库根上一定有的 `moon.mod`：拿它当一份「本地文件」（内容不合法，但走得够远）
  let options = Options::from_matches(
    cli().parse(argv=["moon.mod"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  let (empty, _probe) = @docker_cli.write_fake_cli_named(
    "not-docker", "#!/bin/sh\n",
  )
  let error : CommandError = try {
    load_source(options, env={ "PATH": empty }) |> ignore
    Image("expected an error, got a source")
  } catch {
    Image(message) => Image(message)
    Docker(message) => Docker(message)
    NoLocalImage(message) => NoLocalImage(message)
    Analysis(message) => Analysis(message)
    Registry(message) => Registry(message)
  }
  // 报的是「这不是一份能读的镜像归档」，不是 docker 的错
  assert_true(error is Image(_))
  @docker_cli.remove_fake_cli_dir(empty)
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
    cli().parse(argv=["example:latest", "--verbose"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  assert_true(options.verbose)
  let source = load_source(options, env={ "PATH": dir }, candidates=cli_only()) catch {
    err => fail("the reference should load: \{describe_error(err)}")
  }
  assert_eq(source.layers.length(), 1)

  @docker_cli.remove_fake_cli_dir(dir)
  @docker_cli.remove_temp_bytes(archive_path)
}

///|
/// 端到端：镜像引用遇上「本地没有」的镜像时，先 pull 再 save，
/// 拿到的归档照样走既有分析链路。
///
/// 这是 issue #42 的验收动作，也是 issue #44 的对齐结论：
/// 原版 dive（Go）没有 `--pull` 开关，`ImageInspect` 报 not-found 就直接
/// `docker pull` 一次；这里同样把「缺了就拉」作为默认行为。
async test "a reference pulls a missing image by default" {
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
  let archive_path = @docker_cli.write_temp_bytes("pull.tar", archive)
  let dir = @async_fs.tmpdir(prefix="dive-from-image-pull-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  // `inspect` 失败 = daemon 说本地没有这个镜像
  let script = @docker_cli.fake_recording_cli(
    log,
    archive_path,
    "[]",
    inspect_code=1,
  )
  let (bin, _program) = @docker_cli.write_fake_cli_named("docker", script)

  let options = Options::from_matches(
    cli().parse(argv=["example:latest"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  assert_false(options.no_pull)
  let source = load_source(options, env={ "PATH": bin }, candidates=cli_only()) catch {
    err => fail("the reference should load: \{describe_error(err)}")
  }
  assert_eq(source.layers.length(), 1)

  let calls = @async_fs.read_file(log).text()
  assert_true(calls.contains("pull example:latest"))
  assert_true(
    calls.find("pull example:latest") < calls.find("save example:latest"),
  )

  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_temp_bytes(archive_path)
  @docker_cli.remove_fake_cli_dir(dir)
}

///|
/// 本地已有镜像时不发起拉取：策略是「缺失才拉」，不是「每次都拉」。
async test "a reference leaves a local image alone" {
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
  let archive_path = @docker_cli.write_temp_bytes("local.tar", archive)
  let dir = @async_fs.tmpdir(prefix="dive-from-image-local-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  let script = @docker_cli.fake_recording_cli(
    log, archive_path, "[{\"Id\":\"sha256:cafe\"}]",
  )
  let (bin, _program) = @docker_cli.write_fake_cli_named("docker", script)

  let options = Options::from_matches(
    cli().parse(argv=["example:latest"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  let source = load_source(options, env={ "PATH": bin }, candidates=cli_only()) catch {
    err => fail("the reference should load: \{describe_error(err)}")
  }
  assert_eq(source.layers.length(), 1)

  let calls = @async_fs.read_file(log).text()
  assert_true(calls.contains("inspect example:latest"))
  assert_true(!calls.contains("pull example:latest"))

  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_temp_bytes(archive_path)
  @docker_cli.remove_fake_cli_dir(dir)
}

///|
/// `--no-pull` 的新语义：绝不发起网络请求，但纯本地的 `inspect` / `save` 照常。
///
/// 「本地已有」那一半由 `a reference leaves a local image alone` 守住
/// （同一批 fake CLI，只是不带开关）。这里守的是开关本身**不改变**
/// 「缺了就拉」以外的任何决策：`pull_if_missing` 只是被折成 `false`。
async test "no-pull only folds pull_if_missing" {
  let with_pull = Options::from_matches(
    cli().parse(argv=["example:latest"]) catch {
      err => fail("parse: \{err}")
    },
  )
  let without_pull = Options::from_matches(
    cli().parse(argv=["example:latest", "--no-pull"]) catch {
      err => fail("parse: \{err}")
    },
  )
  assert_false(with_pull.no_pull)
  assert_true(without_pull.no_pull)
  // 其余选项一模一样：`--no-pull` 不是「只看本地文件」，它只拦出网的那两步
  assert_eq(without_pull.image, with_pull.image)
  assert_eq(without_pull.format, with_pull.format)
  assert_eq(without_pull.output, with_pull.output)
  assert_eq(without_pull.no_tui, with_pull.no_tui)
  assert_eq(without_pull.docker_timeout_ms, with_pull.docker_timeout_ms)
}

///|
/// `--no-pull` 下本地**没有**这个镜像：报 `NoLocalImage`，不是大而化之的 `Docker`。
///
/// 「本地没这个镜像」与「这台机器没有 docker」是两件完全不同的事：
/// 前者用户该 `docker pull`（或者去掉 `--no-pull`），后者用户该装 docker。
/// 合并成一句 `Docker` 时只能靠文案里有没有 `no usable docker backend` 分辨。
async test "a reference missing locally under --no-pull reports NoLocalImage" {
  let options = Options::from_matches(
    cli().parse(argv=["nginx:latest", "--no-pull"]) catch {
      err => fail("should parse: \{err}")
    },
  )
  assert_true(options.no_pull)
  // `inspect` 的答案直接喂给分类函数：一条有 docker、但本地没有这个镜像的结局。
  // 这一档的两种失败必须分开报——「本地没这个镜像」与「这台机器没有 docker」
  // 是两件完全不同的事，前者用户该 `docker pull`，后者用户该装 docker。
  let missing = classify_docker_error(
    options,
    @docker_cli.ImageNotFound("nginx:latest"),
  )
  assert_true(missing is NoLocalImage(_))
  assert_true(describe_error(missing).contains("--no-pull forbids pulling"))
  // 没有 `--no-pull` 时同一条错误保持原样：那是「拉取失败了」，不是「不许拉」
  let with_pull = Options::from_matches(
    cli().parse(argv=["nginx:latest"]) catch {
      err => fail("parse: \{err}")
    },
  )
  let pulled = classify_docker_error(
    with_pull,
    @docker_cli.ImageNotFound("nginx:latest"),
  )
  assert_true(pulled is Docker(_))
  // 探不到后端仍然归 `Docker`：`Show` 会带上安装提示
  let no_backend = classify_docker_error(
    options,
    @docker_cli.NoBackend("not found on PATH", ""),
  )
  assert_true(no_backend is Docker(_))
}

///|
/// 三层内存来源：L1 改写 `/etc/hosts`，L2 把它改回 L0 的字节并删掉 `/etc/old`。
///
/// 走 `ImageSource::from_oci_layout` 而不是手拼结构：`ImageSource` 的字段是
/// 包内可见，内存造来源的公开入口就是它。
fn image_of_layers(
  name : String,
  layers : Array[Bytes],
) -> @image_ci.ImageSource raise {
  // config 要带 `rootfs`：`from_oci_layout` 会解析它（真 OCI layout 从来都有）
  @image_ci.ImageSource::from_oci_layout(
    name, "{}", "{\"architecture\":\"amd64\",\"os\":\"linux\",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[]}}",
    layers,
  )
}

///|
/// 解析一段 argv（不含程序名），与 `cli_wbtest.mbt` 同一口径。
fn options_of(args : Array[String]) -> Options raise {
  Options::from_matches(
    cli().parse(argv=args) catch {
      err => fail("should parse: \{err}")
    },
  )
}

///|
/// 只读视图的文本：`render_layer_view` 是纯函数，测试直接断言它的输出，
/// 不必去截 `println` 的 stdout。
async fn layer_view_text(
  options : Options,
  layers : Array[BytesView],
) -> String {
  let views = @layer_tree.browse_layers(layers) catch {
    err => raise CommandError::Analysis(err.to_string())
  }
  let wanted = match options.layer {
    Some(layer) => layer
    None => views.length() - 1
  }
  if wanted < 0 || wanted >= views.length() {
    raise CommandError::Analysis("layer \{wanted} out of range")
  }
  render_layer_view(views[wanted], options, views.length())
}

///|
/// 聚合档与单层档的差别在 CLI 上也成立：同一条路径「被改回原样」时，
/// `--aggregate` 仍把它算进 `modified`，不给开关时按逐层口径（默认行为不变）。
async test "aggregate flag switches the compare range of the layer view" {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
    @layer_tree.TarEntrySpec::File("etc/old", "x"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.2 longer"),
  ])
  let l2 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
    @layer_tree.TarEntrySpec::Whiteout("etc", "old"),
  ])
  let layers : Array[BytesView] = [l0, l1, l2]

  // 单层档：第 2 层相对第 1 层改了 hosts（尺寸不同），old 被删
  let single = layer_view_text(options_of(["demo.tar", "--layer", "2"]), layers)
  assert_true(single.contains("compare: layer"))
  assert_true(single.contains("L1 -> L2"))
  assert_true(single.contains("removed (not in the tree):"))
  assert_true(single.contains("/etc/old"))

  // 聚合档：与第 0 层之前比，hosts 是「这期间被碰过」，old 仍然是被删的那条
  let aggregated = layer_view_text(
    options_of(["demo.tar", "--layer", "2", "--aggregate"]),
    layers,
  )
  assert_true(aggregated.contains("compare: aggregate"))
  assert_true(aggregated.contains("L0 -> L2"))
  assert_true(aggregated.contains("/etc/hosts"))
  assert_true(aggregated.contains("/etc/old"))
  assert_true(aggregated.contains("removed (not in the tree):"))
}

///|
/// 默认档位下 `--layer` 的输出与从前一致：不给 `--aggregate` 时不多不少。
async test "the layer view is unchanged without the aggregate flag" {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "a"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "bb"),
    @layer_tree.TarEntrySpec::File("etc/new", "n"),
  ])
  let layers : Array[BytesView] = [l0, l1]
  let text = layer_view_text(options_of(["demo.tar", "--layer", "1"]), layers)
  assert_true(text.contains("layer 1 of 2"))
  assert_true(text.contains("compare: layer"))
  // 这一档没有删除：不该多出那一段
  assert_false(text.contains("removed (not in the tree):"))
}

///|
/// `--aggregate` 的 JSON：`compare`、`aggregateBytes`、`base` 三个新字段，
/// 既有字段（tree / layer / diff 三组）一个都没动。
async test "aggregate json adds the compare fields" {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "a"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "bb"),
  ])
  let layers : Array[BytesView] = [l0, l1]
  let json = layer_view_json_for(
    options_of(["demo.tar", "--layer", "1", "--aggregate", "--format", "json"]),
    layers,
  )
  assert_true(json.contains("\"compare\": \"aggregate\""))
  // 聚合区间是「第 0 层之前 -> 第 1 层」：多写了 1 个字节（"a" -> "bb"）
  assert_true(json.contains("\"aggregateBytes\": 1"))
  assert_true(json.contains("\"layer\": 1"))
  // 聚合区间的起点是第 0 层的树
  assert_true(json.contains("\"base\": 0"))
  // 既有字段照旧在
  assert_true(json.contains("\"tree\":"))
  assert_true(json.contains("\"modified\":"))
}

///|
/// 与 `layer_view_text` 同形，只是走后者的 JSON 分支。
async fn layer_view_json_for(
  options : Options,
  layers : Array[BytesView],
) -> String {
  let views = @layer_tree.browse_layers(layers) catch {
    err => raise CommandError::Analysis(err.to_string())
  }
  layer_view_to_json(
    views[views.length() - 1],
    compare_diff(views[views.length() - 1], options),
    options,
  ).stringify(indent=2)
}

///|
/// `image_of_layers` 也要有人用：钉住内存来源能造出「多层 + 无压缩」的镜像。
async test "image_of_layers builds a multi-layer source" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "a"),
  ])
  let source = image_of_layers("demo.tar", [layer, layer]) catch {
    err => fail("image source: \{err}")
  }
  assert_eq(source.layers.length(), 2)
  assert_eq(source.format, "oci-layout")
  // 层字节原样带出来，没有压缩信息时按未压缩处理
  assert_true(source.layers[0].data.length() > 0)
}
