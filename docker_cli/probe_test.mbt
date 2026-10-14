///|
/// 探测顺序：DOCKER_HOST → /var/run/docker.sock → docker → podman → nerdctl。
test "default candidates follow the documented order" {
  let env = { "DOCKER_HOST": "unix:///custom/docker.sock" }
  let candidates = @docker_cli.default_candidates(env)
  assert_eq(candidates, [
    @docker_cli.BackendCandidate::Socket("/custom/docker.sock"),
    @docker_cli.BackendCandidate::Socket("/var/run/docker.sock"),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Podman),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Nerdctl),
  ])
}

///|
/// 没设 DOCKER_HOST 时不该凭空多一个候选。
test "missing DOCKER_HOST skips the socket candidate" {
  let candidates = @docker_cli.default_candidates({})
  assert_eq(candidates.length(), 4)
  assert_eq(
    candidates[0],
    @docker_cli.BackendCandidate::Socket("/var/run/docker.sock"),
  )
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
/// `DOCKER_CLI` 指定的工具被提到最前面，其余候选顺序不动。
test "DOCKER_CLI promotes the chosen tool" {
  let env = { "DOCKER_CLI": "/opt/bin/podman" }
  let candidates = @docker_cli.default_candidates(env)
  let promoted = @docker_cli.probe_order_for_test(candidates, env)
  assert_eq(
    promoted[0],
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Podman),
  )
  // 原来的 podman 位置不能重复出现
  let podman_count = promoted.fold(init=0, (acc, candidate) => {
    match candidate {
      @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Podman) => acc + 1
      _ => acc
    }
  })
  assert_eq(podman_count, 1)
}

///|
/// 探测不到任何后端时给 NoBackend，错误信息里逐条列出尝试过的候选。
async test "probing failure lists every attempt" {
  let candidates = [
    @docker_cli.BackendCandidate::Socket("/definitely/missing.sock"),
    @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
  ]
  let probed = @docker_cli.probe_backends(candidates, {})
  assert_true(probed.candidate is None)
  assert_eq(probed.attempts.length(), 2)
  let described = @docker_cli.describe_backends(probed)
  assert_true(described.contains("/definitely/missing.sock"))
  assert_true(described.contains("docker"))
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
async test "resolve_backend reports NoBackend without a daemon" {
  let candidates = [
    @docker_cli.BackendCandidate::Socket("/definitely/missing.sock"),
  ]
  let error = try {
    @docker_cli.resolve_backend(candidates, {}) |> ignore
    fail("should fail")
  } catch {
    err => err
  }
  let text = error.to_string()
  assert_true(text.contains("no usable docker backend"))
  assert_true(text.contains("DOCKER_CLI"))
}
