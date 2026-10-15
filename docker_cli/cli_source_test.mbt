///|
/// CLI 后端对 fake docker 完成 inspect + save。
/// 不依赖真实 daemon，CI 上也能跑。
async test "cli backend inspects and saves through a fake executable" {
  let archive = build_docker_archive([
    (
      "layer0",
      @layer_tree.build_tar([File("etc/hosts", "127.0.0.1 localhost")]),
    ),
    ("layer1", @layer_tree.build_tar([File("etc/hosts", "::1 localhost")])),
  ])
  let archive_path = write_temp_bytes("fake.tar", archive)
  let script = fake_inspect_and_save(
    archive_path, "[{\"Id\":\"sha256:deadbeef\",\"Architecture\":\"amd64\",\"Os\":\"linux\",\"Size\":1234,\"VirtualSize\":5678}]",
  )
  let program = write_fake_cli(script)
  let source = @docker_cli.DockerCliSource::new(
    program,
    tool=@docker_cli.CliTool::Docker,
  )

  let info = source.inspect("example:latest") catch {
    err => fail("inspect should succeed: \{err}")
  }
  assert_eq(info.id, "sha256:deadbeef")
  assert_eq(info.architecture, "amd64")
  assert_eq(info.os, "linux")
  assert_eq(info.size, 1234)
  assert_eq(info.virtual_size, 5678)

  let saved = source.save("example:latest") catch {
    err => fail("save should succeed: \{err}")
  }
  assert_eq(saved, archive)

  remove_fake_cli(program)
  remove_temp_bytes(archive_path)
}

///|
/// 退出码非 0 时，stderr 必须出现在错误信息里，否则排查全靠猜。
async test "cli backend surfaces stderr on failure" {
  let program = write_fake_cli(fake_failing_cli("no such image: nope", 125))
  let source = @docker_cli.DockerCliSource::new(
    program,
    tool=@docker_cli.CliTool::Podman,
  )
  let error = try {
    source.inspect("nope") |> ignore
    fail("inspect should fail")
  } catch {
    err => err
  }
  let text = error.to_string()
  assert_true(text.contains("125"))
  assert_true(text.contains("no such image: nope"))
  remove_fake_cli(program)
}

///|
/// 超时必须能取消子进程，否则 CI 上一个挂住的 daemon 会拖满整个时限。
async test "cli backend cancels a hanging process on timeout" {
  let program = fake_hanging_cli()
  let source = @docker_cli.DockerCliSource::new(
    program,
    tool=@docker_cli.CliTool::Nerdctl,
    timeout_ms=300,
  )
  let started = @env.now().reinterpret_as_int64()
  let error = try {
    source.save("whatever") |> ignore
    fail("save should time out")
  } catch {
    err => err
  }
  let elapsed = @env.now().reinterpret_as_int64() - started
  assert_true(error.to_string().contains("cancelled"))
  // 300ms 超时不该真的等 30 秒的 sleep
  assert_true(elapsed < 5000)
  remove_fake_cli(program)
}

///|
/// 可执行文件不存在时报 ExecutableNotFound，不 panic。
async test "cli backend reports a missing executable" {
  let source = @docker_cli.DockerCliSource::new("/definitely/not/here/docker")
  let error = try {
    source.inspect("x") |> ignore
    fail("inspect should fail")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("executable not found"))
}

///|
/// 空镜像名在进子进程之前就被拦下。
async test "cli backend rejects an empty reference" {
  let source = @docker_cli.DockerCliSource::new("/bin/echo")
  let error = try {
    source.inspect("   ") |> ignore
    fail("inspect should fail")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("invalid image reference"))
}

///|
/// save 出来的空归档当失败处理：docker 对未知镜像会安静地吐空 tar。
async test "cli backend rejects an empty save output" {
  let script =
    #|#!/bin/sh
    #|exit 0
    #|
  let program = write_fake_cli(script)
  let source = @docker_cli.DockerCliSource::new(program)
  let error = try {
    source.save("ghost:latest") |> ignore
    fail("save should fail on empty output")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("empty archive"))
  remove_fake_cli(program)
}

///|
/// save 的参数形态随工具不同：podman 必须显式要 docker-archive 格式。
test "save and inspect arguments differ per tool" {
  assert_eq(
    @docker_cli.save_args(@docker_cli.CliTool::Docker, "nginx:latest"),
    ["save", "nginx:latest"],
  )
  assert_eq(
    @docker_cli.save_args(@docker_cli.CliTool::Nerdctl, "nginx:latest"),
    ["save", "nginx:latest"],
  )
  assert_eq(
    @docker_cli.save_args(@docker_cli.CliTool::Podman, "nginx:latest"),
    ["save", "--format", "docker-archive", "nginx:latest"],
  )
  assert_eq(
    @docker_cli.inspect_args(@docker_cli.CliTool::Docker, "nginx:latest"),
    ["inspect", "nginx:latest"],
  )
  assert_eq(
    @docker_cli.inspect_args(@docker_cli.CliTool::Podman, "nginx:latest"),
    ["inspect", "--format", "json", "nginx:latest"],
  )
}

///|
/// 流式落盘：save 的产出直接写文件，字节数与源归档一致。
async test "cli backend saves to a file without buffering in memory" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit\n"),
  ])
  let archive = build_docker_archive([("beef", layer)])
  let archive_path = write_temp_bytes("src.tar", archive)
  let program = write_fake_cli(
    fake_inspect_and_save(archive_path, "[{\"Id\":\"sha256:beef\"}]"),
  )
  let source = @docker_cli.DockerCliSource::new(program)
  let dir = @fs.tmpdir(prefix="dive-save-")
  let output = "\{dir}/out.tar"
  let written = source.save_to_file("example:latest", output) catch {
    err => fail("save_to_file should succeed: \{err}")
  }
  assert_eq(written, archive.length())
  let readback = @fs.read_file(output).binary()
  assert_eq(readback, archive)
  @fs.rmdir(dir, recursive=true)
  remove_fake_cli(program)
  remove_temp_bytes(archive_path)
}

///|
/// 流式落盘也要拦空归档：退出码为 0 但没写任何字节时当失败。
async test "cli backend save_to_file rejects empty output" {
  let script =
    #|#!/bin/sh
    #|exit 0
    #|
  let program = write_fake_cli(script)
  let source = @docker_cli.DockerCliSource::new(program)
  let dir = @fs.tmpdir(prefix="dive-save-")
  let error = try {
    source.save_to_file("ghost:latest", "\{dir}/out.tar") |> ignore
    fail("should fail on empty output")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("empty archive"))
  @fs.rmdir(dir, recursive=true)
  remove_fake_cli(program)
}

///|
/// 回归：spawn 重试必须用「新开的」管道，不能复用上一次尝试的写端。
///
/// `read_from_process` 造出来的是独占写端，传给子进程后由运行时自动关闭
/// （`after_spawn`）。一次 spawn 失败（ETXTBSY 这类可重试错误）就会把写端关掉；
/// 若重试沿用同一对写端，子进程拿到的是死 fd —— 退出码 0、输出为空，
/// 表现成「docker save 安静地吐了空归档」。CNB 构建机上就是这样翻的车。
///
/// 这里拿 `save_to_file`（stdout 走 `redirect_to_file`，不经过测试进程的 stdout）
/// 做验证：修复前它复用被关掉的重定向，归档根本写不出来。
async test "spawn retry uses a fresh pipe pair and keeps the output" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit\n"),
  ])
  let archive = build_docker_archive([("beef", layer)])
  let archive_path = write_temp_bytes("retry.tar", archive)
  let program = write_fake_cli(
    fake_inspect_and_save(archive_path, "[{\"Id\":\"sha256:beef\"}]"),
  )
  let source = @docker_cli.DockerCliSource::new(program)
  let dir = @fs.tmpdir(prefix="dive-retry-") catch {
    err => fail("tmpdir: \{err}")
  }
  let output = "\{dir}/out.tar"
  let written = source.save_to_file("example:latest", output) catch {
    err => fail("save_to_file should succeed: \{err}")
  }
  assert_eq(written, archive.length())
  assert_eq(@fs.read_file(output).binary(), archive)
  @fs.rmdir(dir, recursive=true)
  remove_fake_cli(program)
  remove_temp_bytes(archive_path)
}

///|
/// `pull` 的参数形态：镜像引用是唯一的位置参数，三个工具没有差异。
test "cli pull takes just the reference" {
  assert_eq(@docker_cli.pull_args("nginx:latest"), ["pull", "nginx:latest"])
  assert_eq(@docker_cli.pull_args("host:5000/app:1.2"), [
    "pull", "host:5000/app:1.2",
  ])
}

///|
/// CLI 后端的 `pull`：真的跑了 `<tool> pull <ref>`，非零退出把 stderr 透传。
async test "cli backend pulls through a fake executable" {
  let dir = @fs.tmpdir(prefix="dive-pull-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  let program = write_fake_cli(
    fake_recording_cli(log, "\{dir}/unused.tar", "[]"),
  )
  let source = @docker_cli.DockerCliSource::new(
    program,
    tool=@docker_cli.CliTool::Docker,
  )
  source.pull("nginx:latest") catch {
    err => fail("pull should succeed: \{err}")
  }
  let logged = @fs.read_file(log).text()
  assert_true(logged.has_prefix("pull nginx:latest"))
  assert_true(logged.contains("pull nginx:latest"))

  remove_fake_cli(program)
  @fs.rmdir(dir, recursive=true)
}

///|
/// `pull` 失败（镜像不存在 / registry 不可达）要把子进程的 stderr 带出来，
/// 不能只给一句「退出码非 0」。
async test "cli pull surfaces stderr on failure" {
  let program = write_fake_cli(fake_failing_cli("manifest unknown: nope", 1))
  let source = @docker_cli.DockerCliSource::new(program)
  let error = try {
    source.pull("nope:latest") |> ignore
    fail("pull should fail")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("manifest unknown: nope"))
  remove_fake_cli(program)
}

///|
/// 空镜像名在进子进程之前就拦下。
async test "cli pull rejects an empty reference" {
  let program = write_fake_cli("#!/bin/sh\nexit 0\n")
  let source = @docker_cli.DockerCliSource::new(program)
  let error = try {
    source.pull("   ") |> ignore
    fail("pull should reject an empty reference")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("invalid image reference"))
  remove_fake_cli(program)
}
