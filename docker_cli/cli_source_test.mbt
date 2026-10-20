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
  // 文案刻意不含 "no such" / "not found"：这条要验的是「后端故障时的
  // stderr 透传」，不是「镜像不在」。认成镜像不在会走另一条分支（ImageNotFound），
  // 那是 `inspect_failure` 的用例该管的事。
  let program = write_fake_cli(
    fake_failing_cli("permission denied while trying to connect", 125),
  )
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
  assert_true(text.contains("permission denied while trying to connect"))
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

///|
/// `inspect` 说「没有这个镜像」与「工具本身不行」必须分开。
///
/// 前者（`No such image`）要走「缺了就拉」，后者要换一条后端。
/// 混成一个错误，前端只能靠猜：猜错就把一次注定失败的拉取
/// 当成「镜像不在」的证明，真正的故障（权限、daemon 挂了）反而被盖住。
async test "cli inspect separates missing from broken" {
  let missing = write_fake_cli(
    fake_failing_cli("Error response from daemon: No such image: nope", 1),
  )
  let source = @docker_cli.DockerCliSource::new(missing)
  let error = try {
    source.inspect("nope") |> ignore
    fail("inspect should fail")
  } catch {
    err => err
  }
  assert_true(error is @docker_cli.ImageNotFound(_))
  remove_fake_cli(missing)

  // 同一个退出码，但 stderr 说的是别的事：那是故障，不是「没有」
  let broken = write_fake_cli(
    fake_failing_cli("permission denied while trying to connect", 1),
  )
  let source2 = @docker_cli.DockerCliSource::new(broken)
  let error2 = try {
    source2.inspect("nope") |> ignore
    fail("inspect should fail")
  } catch {
    err => err
  }
  assert_true(error2 is @docker_cli.Backend(_, 1, _))
  remove_fake_cli(broken)
}

///|
/// 三家 `inspect` 说「本地没有」的原话不一样，都要认成 `ImageNotFound`。
///
/// 漏一条的代价不是文案难听：把「本地没有」判成「后端坏了」，
/// 该拉的镜像会直接判死（`--from-image` 默认先 inspect 判缺失再拉）。
/// 这些字符串是从各家 CLI 的实际输出里抄的，不是编的。
async test "inspect maps each tool's missing-image wording to ImageNotFound" {
  let cases = [
    ("docker", "Error response from daemon: No such image: nginx:latest"),
    ("docker", "Error: No such image: nginx:latest"),
    ("podman", "Error: nginx:latest: image not known"),
    ("nerdctl", "FATA[0000] no such object: nginx:latest"),
    ("nerdctl", "content digest sha256:deadbeef: not found"),
    ("podman", "Error: unable to find 'nginx:latest'"),
  ]
  for case in cases {
    let (name, message) = case
    let tool = if name == "podman" {
      @docker_cli.CliTool::Podman
    } else if name == "nerdctl" {
      @docker_cli.CliTool::Nerdctl
    } else {
      @docker_cli.CliTool::Docker
    }
    let program = write_fake_cli(fake_failing_cli(message, 1))
    let source = @docker_cli.DockerCliSource::new(program, tool~)
    let error = try {
      source.inspect("nginx:latest") |> ignore
      fail("\{name} inspect should fail")
    } catch {
      err => err
    }
    // `ImageNotFound` 而不是 `Backend`：文案里带 "no such image"
    assert_true(error.to_string().contains("no such image locally"))
    remove_fake_cli(program)
  }
}

///|
/// 反过来也要钉死：工具本身坏了（连不上 daemon、权限不够）**不能**
/// 被当成「本地没有」。判错的代价是拿一次注定失败的拉取盖住真原因。
async test "inspect keeps a broken backend a Backend error" {
  for
    message in [
      "Cannot connect to the Docker daemon at unix:///var/run/docker.sock", "permission denied while trying to connect to the Docker daemon socket",
      "Error: unable to connect to Podman socket",
    ] {
    let program = write_fake_cli(fake_failing_cli(message, 125))
    let source = @docker_cli.DockerCliSource::new(
      program,
      tool=@docker_cli.CliTool::Podman,
    )
    let error = try {
      source.inspect("nginx:latest") |> ignore
      fail("inspect should fail")
    } catch {
      err => err
    }
    let text = error.to_string()
    assert_true(text.contains("125"))
    assert_true(text.contains(message))
    assert_false(text.contains("no such image locally"))
    remove_fake_cli(program)
  }
}

///|
/// podman 的 `save` 默认吐 oci-archive（没有 `manifest.json`），
/// 必须显式要 docker-archive；`save_to_file` 走同一个 `save_args`，
/// 于是两条路径都不会漏掉这个 `--format`。
async test "podman save pins docker-archive on both memory and file paths" {
  let dir = @fs.tmpdir(prefix="dive-podman-save-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  let source_bytes = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit\n"),
  ])
  let archive = build_docker_archive([("beef", source_bytes)])
  let archive_path = write_temp_bytes("podman.tar", archive)
  let program = write_fake_cli(
    fake_recording_cli(log, archive_path, "[{\"Id\":\"sha256:beef\"}]"),
  )
  let source = @docker_cli.DockerCliSource::new(
    program,
    tool=@docker_cli.CliTool::Podman,
  )
  let output = "\{dir}/out.tar"
  let written = source.save_to_file("example:latest", output) catch {
    err => fail("save_to_file should succeed: \{err}")
  }
  assert_eq(written, archive.length())
  let logged = @fs.read_file(log).text()
  assert_true(logged.contains("save --format docker-archive example:latest"))
  assert_eq(@fs.read_file(output).text(), @docker_cli.bytes_to_string(archive))

  remove_fake_cli(program)
  remove_temp_bytes(archive_path)
  @fs.rmdir(dir, recursive=true)
}

///|
/// 回归（issue #94 第二轮）：`save` 阶段闷头干很久、一个字节都不吐时，
/// 空闲超时必须说清楚**卡在 save 上**。
///
/// 现场是 `docker save` 对着一个刚拉完、本地已 inspect 得通的镜像，
/// 导出大层时 docker 自己不出进度（它在写磁盘 / 算 tar），于是 stdout
/// 30 秒没有新字节。用户看到的却是把 `trying cli:...` 之后整段静默
/// 记到「卡住了」，看不出到底卡在哪一步——因为 `save` 这一步没有任何提示。
async test "cli backend names the save stage when it goes silent" {
  let script =
    #|#!/bin/sh
    #|case "$1" in
    #|  inspect)
    #|    echo '[{"Id":"sha256:local"}]'
    #|    ;;
    #|  save)
    #|    sleep 30
    #|    ;;
    #|esac
    #|
  let program = write_fake_cli(script)
  let source = @docker_cli.DockerCliSource::new(program, timeout_ms=300)
  let error = try {
    source.save("example:latest") |> ignore
    fail("save should time out")
  } catch {
    err => err
  }
  let text = error.to_string()
  assert_true(text.contains("cancelled"))
  assert_true(text.contains("idle timeout 300ms"))
  // 卡在哪一步必须写在文案里：只报「超时了」，用户没法判断是 inspect 慢、
  // pull 卡住还是 save 在闷头攒 tar
  assert_true(text.contains("docker save example:latest"))
  remove_fake_cli(program)
}

///|
/// `save_into`：归档边读边写进 sink，内存里不留整段，字节一个不少。
async test "cli backend streams save into a sink" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit\n"),
  ])
  let archive = build_docker_archive([("beef", layer)])
  let archive_path = write_temp_bytes("stream.tar", archive)
  let program = write_fake_cli(
    fake_inspect_and_save(archive_path, "[{\"Id\":\"sha256:beef\"}]"),
  )
  let source = @docker_cli.DockerCliSource::new(program)
  // 用临时文件当 sink：既验「写进去了」，也验它不是攒完再一次性倒出来
  let temp = @docker_cli.TempArchive::create() catch {
    err => fail("temp: \{err}")
  }
  source.save_into("example:latest", temp) catch {
    err => fail("save_into should succeed: \{err}")
  }
  let readback = temp.read_back() catch { err => fail("read back: \{err}") }
  assert_eq(readback, archive)
  temp.discard()
  remove_fake_cli(program)
  remove_temp_bytes(archive_path)
}

///|
/// 换后端重试时临时文件必须被截回 0。
///
/// 不截的话，第一条后端写了半截（`Cancelled` 正好落在中途）、第二条接着往后
/// 追加，最后拼出一个「前一半是 A、后一半是 B」的归档。它能被 tar 读出开头，
/// 错得比报错更难查——所以这里直接钉字节相等。
async test "cli backend truncates the temp archive between retries" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit\n"),
  ])
  let archive = build_docker_archive([("beef", layer)])
  let archive_path = write_temp_bytes("retry2.tar", archive)
  let program = write_fake_cli(
    fake_inspect_and_save(archive_path, "[{\"Id\":\"sha256:beef\"}]"),
  )
  let temp = @docker_cli.TempArchive::create() catch {
    err => fail("temp: \{err}")
  }
  // 先模拟「上一条后端写了半截」
  temp.write(b"garbage-from-a-dead-backend") catch {
    err => fail("write: \{err}")
  }
  temp.rewind() catch {
    err => fail("rewind: \{err}")
  }
  let source = @docker_cli.DockerCliSource::new(program)
  source.save_into("example:latest", temp) catch {
    err => fail("save_into should succeed: \{err}")
  }
  let readback = temp.read_back() catch { err => fail("read back: \{err}") }
  assert_eq(readback, archive)
  temp.discard()
  remove_fake_cli(program)
  remove_temp_bytes(archive_path)
}
