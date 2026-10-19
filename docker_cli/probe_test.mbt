///|
/// 探测顺序：DOCKER_HOST → CONTAINER_HOST → /var/run/docker.sock →
/// podman socket → docker → podman → nerdctl。
///
/// 显式声明的两个 socket 排在系统默认值前面，两个系统 socket 一起上——
/// 容器环境里常只跑其中一只 daemon，少一条就多一次「明明装了却取不到」。
test "default candidates follow the documented order" {
  let env = {
    "DOCKER_HOST": "unix:///custom/docker.sock",
    "CONTAINER_HOST": "unix:///custom/podman.sock",
  }
  let candidates = @docker_cli.default_candidates(env)
  assert_eq(candidates, [
    @docker_cli.BackendCandidate::Socket("/custom/docker.sock"),
    @docker_cli.BackendCandidate::Socket("/custom/podman.sock"),
    @docker_cli.BackendCandidate::Socket("/var/run/docker.sock"),
    @docker_cli.BackendCandidate::Socket("/run/podman/podman.sock"),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Podman),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Nerdctl),
  ])
}

///|
/// 没设 DOCKER_HOST / CONTAINER_HOST 时不该凭空多一个 socket 候选，
/// 但两个系统默认 socket 要在。
test "missing DOCKER_HOST still yields both system sockets" {
  let candidates = @docker_cli.default_candidates({})
  assert_eq(candidates.length(), 5)
  assert_eq(
    candidates[0],
    @docker_cli.BackendCandidate::Socket("/var/run/docker.sock"),
  )
  assert_eq(
    candidates[1],
    @docker_cli.BackendCandidate::Socket("/run/podman/podman.sock"),
  )
}

///|
/// podman 的 `CONTAINER_HOST` 是裸路径（不带 `unix://`），也要收。
/// 同一条 socket 被两个变量重复指定时只留一条，别探两遍。
test "CONTAINER_HOST accepts a bare path and dedupes" {
  assert_eq(
    @docker_cli.unix_socket_of("/run/podman/podman.sock"),
    Some("/run/podman/podman.sock"),
  )
  // 两个变量指向同一条 socket：只该留一条
  let candidates = @docker_cli.default_candidates({
    "DOCKER_HOST": "unix:///tmp/shared.sock",
    "CONTAINER_HOST": "/tmp/shared.sock",
  })
  let shared = candidates.fold(init=0, (acc, candidate) => {
    match candidate {
      @docker_cli.BackendCandidate::Socket(path) if path == "/tmp/shared.sock" =>
        acc + 1
      _ => acc
    }
  })
  assert_eq(shared, 1)
}

///|
/// podman rootless 的 socket 路径由 `XDG_RUNTIME_DIR` 推出来，
/// 没设时退回 `/run/user/<uid>`。
test "podman rootless socket path derives from XDG_RUNTIME_DIR or UID" {
  assert_eq(
    @docker_cli.podman_rootless_socket({ "XDG_RUNTIME_DIR": "/run/user/1000" }),
    Some("/run/user/1000/podman/podman.sock"),
  )
  // 尾巴上的斜杠不该拼成双斜杠
  assert_eq(
    @docker_cli.podman_rootless_socket({ "XDG_RUNTIME_DIR": "/run/user/1000/" }),
    Some("/run/user/1000/podman/podman.sock"),
  )
  assert_eq(
    @docker_cli.podman_rootless_socket({ "UID": "1000" }),
    Some("/run/user/1000/podman/podman.sock"),
  )
  assert_true(@docker_cli.podman_rootless_socket({}) is None)
}

///|
/// `tcp://` / `ssh://` 属于后续 issue 的范围内，这里明确跳过。
test "non-unix DOCKER_HOST is skipped" {
  for
    host in ["tcp://1.2.3.4:2375", "ssh://user@host", "npipe:////./pipe/docker"] {
    assert_true(@docker_cli.unix_socket_of(host) is None)
  }
  assert_eq(
    @docker_cli.unix_socket_of("unix:///var/run/docker.sock"),
    Some("/var/run/docker.sock"),
  )
}

///|
/// `DOCKER_CLI` 指定的文件被提到最前面，其余候选顺序不动。
///
/// 提上来的是 `Program(路径, ...)` 而**不是** `Cli(工具名)`：
/// `DOCKER_CLI` 写的是「用哪个文件」，不是「去 PATH 上找哪个名字」。
/// 折回 `Cli(tool)` 会把路径扔掉，用户写死的程序根本不会被调用。
test "DOCKER_CLI promotes the explicit program" {
  let env = { "DOCKER_CLI": "/opt/bin/podman" }
  let candidates = @docker_cli.default_candidates(env)
  let promoted = @docker_cli.probe_order_for_test(candidates, env)
  assert_eq(
    promoted[0],
    @docker_cli.BackendCandidate::Program(
      "/opt/bin/podman",
      @docker_cli.CliTool::Podman,
    ),
  )
  // 同名工具的 PATH 候选要摘掉：同一个 podman 不该探两遍
  let podman_count = promoted.fold(init=0, (acc, candidate) => {
    match candidate {
      @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Podman) => acc + 1
      @docker_cli.BackendCandidate::Program(_, @docker_cli.CliTool::Podman) =>
        acc + 1
      _ => acc
    }
  })
  assert_eq(podman_count, 1)
}

///|
/// `DOCKER_CLI` 指向 PATH 之外的文件时，探测要认这个路径本身。
///
/// 这是 issue #42 的一个真实坑：`DOCKER_CLI=/opt/bin/docker` 而 `docker`
/// 不在 PATH 上时，旧实现拿 basename 去 PATH 上找 → 报 `not found on PATH`，
/// 用户写死的路径等于白写。
async test "DOCKER_CLI outside PATH is still usable" {
  // 真造一个目录外的可执行文件：PATH 指向别处，路径本身才作数
  let dir = @fs.tmpdir(prefix="dive-docker-cli-")
  let program = "\{dir}/docker"
  @fs.write_file(program, "#!/bin/sh\nexit 0\n", permission=0o755)
  let env = {
    "DOCKER_CLI": program,
    // PATH 里没有 docker
    "PATH": "/nonexistent",
  }
  let resolved = @docker_cli.resolve_candidate_for_test(
    @docker_cli.BackendCandidate::Program(program, @docker_cli.CliTool::Docker),
    env,
  )
  assert_eq(resolved, Some(program))
  @fs.rmdir(dir, recursive=true)
}

///|
/// 探测不到任何后端时给 NoBackend，错误信息里逐条列出尝试过的候选。
///
/// `PATH` 必须显式指向空目录，两层原因叠在一起：
///
/// - `env` 里没有 `PATH` 时 `probe_backends` 会回落到进程环境；
/// - `resolve_executable` 还会兜 `/usr/bin` 这类系统目录
///   （GUI / cron 场景的兜底，本身是对的）。
///
/// 于是「这台机器装没装 docker」直接决定用例过不过：CI 镜像里
/// `/usr/bin/docker` 是真实存在的，`Cli(Docker)` 会被判成可用，
/// 探测提前选中，`candidate is None` 就不成立。
async test "probing failure lists every attempt" {
  let dir = @fs.tmpdir(prefix="dive-probe-")
  let candidates = [
    @docker_cli.BackendCandidate::Socket("/definitely/missing.sock"),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
  ]
  // 空临时目录：既没有 docker，也不会被 /usr/bin 兜底捡回来
  let probed = @docker_cli.probe_backends(candidates, { "PATH": dir })
  assert_true(probed.candidate is None)
  assert_eq(probed.attempts.length(), 2)
  let described = @docker_cli.describe_backends(probed)
  assert_true(described.contains("/definitely/missing.sock"))
  assert_true(described.contains("docker"))
  @fs.rmdir(dir, recursive=true)
}

///|
/// 探测到第一个健康候选就停下，不再往下找。
///
/// 用一个真实存在的可执行文件当「能用的 docker」：`PATH` 里塞临时目录，
/// 这样不必依赖机器上真的装了什么。
async test "probing stops at the first healthy candidate" {
  let dir = @fs.tmpdir(prefix="dive-probe-")
  let script =
    #|#!/bin/sh
    #|exit 0
    #|
  @fs.write_file("\{dir}/docker", script, permission=0o755)
  let env = { "PATH": dir }
  let candidates = [
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Podman),
  ]
  let probed = @docker_cli.probe_backends(candidates, env)
  assert_eq(probed.index, 0)
  assert_true(probed.attempts.length() == 1)
  assert_true(probed.candidate is Some(_))
  @fs.rmdir(dir, recursive=true)
}

///|
/// socket 存在但不是 socket（比如被替换成了普通文件）时报明确原因，
/// 而不是当作可用后端继续跑。
async test "a non-socket path is not treated as a healthy socket" {
  let dir = @fs.tmpdir(prefix="dive-probe-")
  let path = "\{dir}/not-a-socket"
  @fs.write_file(path, b"")
  let probed = @docker_cli.probe_backends(
    [@docker_cli.BackendCandidate::Socket(path)],
    {},
  )
  assert_true(probed.candidate is None)
  assert_true(probed.attempts[0].reason.contains("not a socket"))
  @fs.rmdir(dir, recursive=true)
}

///|
/// 无 daemon 环境下 resolve_backend 抛 NoBackend，不 panic。
///
/// `PATH` 同样钉在空临时目录上：只放一个 socket 候选时看似跟 PATH 无关，
/// 但探到了真实 docker 就会走另一条分支，用例变成「取决于机器装没装」。
/// `PATH` 不显式钉死时还要小心递归：进程 PATH 上就装着 docker 的机器上，
/// 探测会先选中它，这里就不再是 NoBackend。
async test "resolve_backend reports NoBackend without a daemon" {
  let dir = @fs.tmpdir(prefix="dive-probe-")
  let candidates = [
    @docker_cli.BackendCandidate::Socket("/definitely/missing.sock"),
  ]
  let error = try {
    @docker_cli.resolve_backend(candidates, { "PATH": dir }) |> ignore
    fail("should fail")
  } catch {
    err => err
  }
  let text = error.to_string()
  assert_true(text.contains("no usable docker backend"))
  assert_true(text.contains("DOCKER_CLI"))
  @fs.rmdir(dir, recursive=true)
}

///|
/// socket 文件在、但对端不答：探测要判它**不可用**，而不是当选中的后端。
///
/// 这是 issue #42「完全没有任何输出」的根因。CNB / 容器里
/// `/var/run/docker.sock` 是外层转发进来的：文件在、`connect(2)` 也立刻成功，
/// 但对端（真 daemon）不通。旧实现只看文件类型就判可用，之后的请求
/// 停在「等状态行」上永远不返回 —— 用户看到的就是「跑起来啥也没有」。
///
/// 现在探测阶段就发一次有超时的 `_ping`：不答就换下一个候选，并把原因写进记录。
#cfg(not(platform="windows"))
async test "a socket that never answers _ping is not healthy" {
  let server = @docker_cli.UnixSocketServer::start()
  // accept 之后什么都不回：模拟半死的转发 socket
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      let conn = server.accept() catch { _ => return }
      @async.sleep(3000)
      conn.close()
    })
    let probed = @docker_cli.probe_backends(
      [@docker_cli.BackendCandidate::Socket(server.path)],
      {},
      timeout_ms=300,
    )
    assert_true(probed.candidate is None)
    assert_true(probed.attempts[0].reason.contains("does not answer"))
    // 理由里路径只该出现一次：`Backend` 的 Show 已经带了 `<path> failed: `，
    // 外层再拼一次就成了「路径念两遍」，看日志的人要猜哪层才是真的
    assert_eq(count_occurrences(probed.attempts[0].reason, server.path), 1)
  })
  server.close()
}

///|
/// socket 真能答 `_ping` 时才算健康，理由里写明是探活过的。
#cfg(not(platform="windows"))
async test "a socket that answers _ping is healthy" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, _request => {
        @utf8.encode("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
      })
    })
    let probed = @docker_cli.probe_backends(
      [@docker_cli.BackendCandidate::Socket(server.path)],
      {},
      timeout_ms=1000,
    )
    assert_eq(probed.index, 0)
    assert_true(probed.attempts[0].reason.contains("_ping"))
  })
  server.close()
}

///|
/// 默认超时必须是**有限**的。
///
/// 这条是一条「不许再退回无超时」的守门：0 表示永远等下去，
/// 半死的 daemon 就会让 `dive --from-image` 静默挂住——
/// 与 `--verbose` 都打不出任何东西的表现完全一致。
test "the default timeout is finite" {
  assert_true(@docker_cli.default_timeout_ms > 0)
}

///|
/// 子串出现次数：`probe_test` 用它确认「路径只被念一遍」，
/// `transport_test` 的 stall 用例也复用同一条断言。
fn count_occurrences(text : String, needle : String) -> Int32 {
  let mut count = 0
  let mut rest = text
  while true {
    match rest.find(needle) {
      None => break
      Some(index) => {
        count = count + 1
        rest = rest[index + needle.length():].to_owned()
      }
    }
  }
  count
}
