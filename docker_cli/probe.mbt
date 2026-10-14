///|
/// 默认探测顺序：`DOCKER_HOST` → `/var/run/docker.sock` → PATH 上的
/// docker → podman → nerdctl。issue #17 要求「可配置」，因此这里返回候选列表
/// 而不是直接探测，调用方可以删改顺序。
pub fn default_candidates(env : Map[String, String]) -> Array[BackendCandidate] {
  let candidates = []
  match env.get("DOCKER_HOST") {
    Some(host) =>
      match unix_socket_of(host) {
        Some(path) => candidates.push(Socket(path))
        None => ()
      }
    None => ()
  }
  candidates.push(Socket("/var/run/docker.sock"))
  candidates.push(Cli(CliTool::Docker))
  candidates.push(Cli(CliTool::Podman))
  candidates.push(Cli(CliTool::Nerdctl))
  candidates
}

///|
/// `DOCKER_HOST=unix:///var/run/docker.sock` → `/var/run/docker.sock`。
/// `tcp://` / `ssh://` 属于后续 issue，这里返回 `None`（跳过这项）。
pub fn unix_socket_of(host : String) -> String? {
  let trimmed = host.trim()
  if trimmed.has_prefix("unix://") {
    let path = trimmed[7:].to_owned()
    if path.is_empty() {
      None
    } else {
      Some(path)
    }
  } else {
    None
  }
}

///|
/// 依次探测候选，停在第一个可用的上。`DOCKER_CLI` 若显式指定，
/// 会提到最前面——用户都写死了，别跟他争。
///
/// 探测本身只做「能不能用」的判定，不真的跑 `save`：
/// socket 看文件在不在，CLI 看 PATH 上解析不解析得到。
pub async fn probe_backends(
  candidates : Array[BackendCandidate],
  env : Map[String, String],
) -> ProbedBackend {
  let ordered = with_cli_override(candidates, env)
  let path = path_of_env(env)
  let attempts = []
  for index, candidate in ordered {
    let (ok, reason) = health_check(candidate, path)
    attempts.push({ candidate, ok, reason, })
    if ok {
      return { index, candidate: Some(candidate), attempts, }
    }
  }
  { index: -1, candidate: None, attempts, }
}

///|
/// 测试入口：暴露 `DOCKER_CLI` 重排逻辑，不必真的探测一遍。
pub fn probe_order_for_test(
  candidates : Array[BackendCandidate],
  env : Map[String, String],
) -> Array[BackendCandidate] {
  with_cli_override(candidates, env)
}

///|
/// `DOCKER_CLI=/opt/bin/docker` 时，把它对应的候选提到第一位。
fn with_cli_override(
  candidates : Array[BackendCandidate],
  env : Map[String, String],
) -> Array[BackendCandidate] {
  match env.get("DOCKER_CLI") {
    None => candidates
    Some(program) => {
      let name = base_name_of(program)
      let promoted = []
      let rest = []
      for candidate in candidates {
        match candidate {
          BackendCandidate::Cli(tool) if Some(tool) == tool_of_name(name) => ()
          _ => rest.push(candidate)
        }
      }
      if tool_of_name(name) is Some(_) {
        // 显式指定了 DOCKER_CLI：即使文件名不认识，也当 docker 用
        let tool = match tool_of_name(name) {
          Some(tool) => tool
          None => CliTool::Docker
        }
        promoted.push(BackendCandidate::Cli(tool))
      }
      promoted + rest
    }
  }
}

///|
/// `/usr/bin/docker` → `docker`
fn base_name_of(path : String) -> String {
  let slash = path.rev_find("/")
  match slash {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
}

///|
/// 可执行文件名 → 工具枚举。不认识的名字交给 `DOCKER_CLI` 直接当 docker 用。
fn tool_of_name(name : String) -> CliTool? {
  if name == "docker" {
    Some(CliTool::Docker)
  } else if name == "podman" {
    Some(CliTool::Podman)
  } else if name == "nerdctl" {
    Some(CliTool::Nerdctl)
  } else {
    None
  }
}

///|
/// 单个候选的可用性判定。
#warnings("-unused_async")
async fn health_check(
  candidate : BackendCandidate,
  path : String,
) -> (Bool, String) {
  match candidate {
    Socket(path) => {
      let kind = @fs.kind(path) catch { _ => @fs.FileKind::Unknown }
      if kind is @fs.FileKind::Socket {
        (true, "socket exists")
      } else if kind is @fs.FileKind::Unknown {
        (false, "socket not found at \{path}")
      } else {
        (false, "\{path} exists but is not a socket")
      }
    }
    Cli(tool) =>
      match resolve_executable(Show::to_string(tool), path) {
        Some(found) => (true, "found at \{found}")
        None => (false, "not found on PATH")
      }
  }
}

///|
/// 在 PATH 上找可执行文件，找不到再兜几个常见安装路径。
///
/// 只做「存在 + 可执行」判定，不真的跑 `--version`：
/// 探测本身不应该产生副作用，否则 CI 里一个慢二进制就能拖死启动。
pub async fn resolve_executable(name : String, path : String) -> String? {
  if name.contains("/") {
    // 已经是路径，只看它在不在
    return if is_executable_file(name) { Some(name) } else { None }
  }
  for directory in split_search_path(path) {
    let candidate = if directory == "" {
      name
    } else if directory.has_suffix("/") {
      directory + name
    } else {
      "\{directory}/\{name}"
    }
    if is_executable_file(candidate) {
      return Some(candidate)
    }
  }
  for directory in fallback_directories() {
    let candidate = "\{directory}/\{name}"
    if is_executable_file(candidate) {
      return Some(candidate)
    }
  }
  None
}

///|
/// 探测用哪个 `PATH`：显式传给 `probe_backends` 的 `env` 优先，
/// 缺省回落到进程环境。测试靠这个钉住「只认临时目录里的 fake docker」。
fn path_of_env(env : Map[String, String]) -> String {
  match env.get("PATH") {
    Some(value) => value
    None =>
      match @env.get_env_var("PATH") {
        Some(value) => value
        None => ""
      }
  }
}

///|
/// PATH 拆成目录列表。空条目保留，按 POSIX 语义当「当前目录」处理。
fn split_search_path(path : String) -> Array[String] {
  let directories = []
  for part in path.split(":") {
    directories.push(part.to_owned())
  }
  directories
}

///|
/// PATH 之外再兜几个常见位置：GUI 启动的进程、以及不带 PATH 的 cron。
fn fallback_directories() -> Array[String] {
  [
    "/usr/bin", "/usr/local/bin", "/bin", "/opt/homebrew/bin", "/usr/local/lib/docker/cli-plugins",
  ]
}

///|
/// 「是个可执行文件」：存在 + 不是目录 + 有执行位。
async fn is_executable_file(path : String) -> Bool {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return false
  }
  let kind = @fs.kind(path) catch { _ => return false }
  if kind is Directory {
    return false
  }
  @fs.can_execute(path) catch {
    _ => false
  }
}
