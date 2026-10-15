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
/// 探测只做「能不能用」的判定，不真的跑 `save`：
/// socket 发一个**有超时的** `_ping`（文件在 ≠ daemon 活着，见 `socket_health`），
/// CLI 看 PATH 上解析不解析得到。
///
/// `timeout_ms` 是单次探测的时间上限。`<= 0` 表示不设超时——
/// 那正是「socket 半死 → 静默挂住」的老问题，测试里显式传 0 时自己负责。
pub async fn probe_backends(
  candidates : Array[BackendCandidate],
  env : Map[String, String],
  timeout_ms~ : Int32 = 0,
) -> ProbedBackend {
  let ordered = with_cli_override(candidates, env)
  let path = path_of_env(env)
  // 调用方显式给了 PATH，就只在这个范围里找：否则装了 docker 的机器上
  // 怎么探都是「找得到」，确定性测试和隔离环境都会失真。
  let allow_fallback = env.get("PATH") is None
  let attempts = []
  for index, candidate in ordered {
    let (ok, reason) = health_check(
      candidate,
      path,
      timeout_ms~,
      allow_fallback~,
    )
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
/// `DOCKER_CLI=/opt/bin/docker` 时，把它**这个文件**提到第一位。
///
/// 关键是「这个文件」：先前的实现只按 basename 认工具，然后把它折回
/// `Cli(tool)`，等于把 `DOCKER_CLI` 里的路径扔了——探测和调用都变成
/// 「去 PATH 上找叫 docker 的东西」。用户显式写了路径却根本不生效，
/// 正是这个坑（`DOCKER_CLI=/opt/bin/docker` 而 `docker` 不在 PATH 时
/// 会直接报 `not found on PATH`）。
///
/// 文件名认不出来时也照样用这个路径，工具类型按 docker 记——用户都写死了，
/// 别跟他争。
fn with_cli_override(
  candidates : Array[BackendCandidate],
  env : Map[String, String],
) -> Array[BackendCandidate] {
  match env.get("DOCKER_CLI") {
    None => candidates
    Some(program) => {
      let name = base_name_of(program)
      let tool = match tool_of_name(name) {
        Some(tool) => tool
        None => CliTool::Docker
      }
      // 同名的 `Cli(tool)` 候选要摘掉，避免同一个工具探两遍
      let rest = []
      for candidate in candidates {
        match candidate {
          BackendCandidate::Cli(candidate_tool) if candidate_tool == tool => ()
          _ => rest.push(candidate)
        }
      }
      [BackendCandidate::Program(program, tool)] + rest
    }
  }
}

///|
/// 一个候选最终会用哪个可执行文件。
///
/// `Program` 原样返回它带的路径（`DOCKER_CLI` 的语义就是「用这个文件」）；
/// `Cli` 按 `PATH` + 常见目录解析。与 `resolve_backend` 的选择口径一致，
/// 测试用它钉住「`DOCKER_CLI` 在 PATH 之外也得能用」这条。
pub async fn resolve_candidate_for_test(
  candidate : BackendCandidate,
  env : Map[String, String],
) -> String? {
  let path = path_of_env(env)
  let allow_fallback = env.get("PATH") is None
  match candidate {
    Socket(_) => None
    Program(program, _) =>
      if is_executable_file(program) {
        Some(program)
      } else {
        None
      }
    Cli(tool) =>
      resolve_executable_opts(Show::to_string(tool), path, allow_fallback~)
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
async fn health_check(
  candidate : BackendCandidate,
  path : String,
  timeout_ms~ : Int32,
  allow_fallback~ : Bool,
) -> (Bool, String) {
  match candidate {
    Socket(path) =>
      match socket_health(path, timeout_ms~) {
        Some(reason) => (false, reason)
        None => (true, "socket answers _ping")
      }
    Cli(tool) =>
      match
        resolve_executable_opts(Show::to_string(tool), path, allow_fallback~) {
        Some(found) => (true, "found at \{found}")
        None => (false, "not found on PATH")
      }
    // `DOCKER_CLI` 给的是路径：就看这个路径在不在、可不可执行，
    // 不回落 PATH / 常见目录——用户指的是哪个文件就是哪个
    Program(program, _) =>
      if is_executable_file(program) {
        (true, "explicit DOCKER_CLI at \{program}")
      } else {
        (false, "DOCKER_CLI=\{program} is not an executable file")
      }
  }
}

///|
/// socket 候选的真实可用性：先看文件是不是 socket，再发一个**有超时的** `_ping`。
///
/// 「文件是个 socket」不等于「daemon 活着」。CNB / 容器里常见的情形是
/// `/var/run/docker.sock` 由外层**转发**进来：文件在、`connect(2)` 也立刻成功，
/// 但对端（真正的 daemon）可能不通。旧实现只看文件类型就判「可用」，
/// 于是后面的请求停在「等状态行」上不动——用户看到的就是「跑起来啥也没有」。
///
/// 这里把这一步前移成一个有界的探活：通了才算可用，不通就把 socket 这个候选
/// 让给后面的 CLI 候选，并在探测记录里写明为什么（`--verbose` 能看见）。
/// `timeout_ms <= 0` 时不设上限——只在测试里有意义，生产入口默认非 0。
///
/// 返回 `None` 表示健康，`Some(reason)` 是失败原因（给人看的一行话）。
async fn socket_health(path : String, timeout_ms~ : Int32) -> String? {
  let kind = @fs.kind(path) catch { _ => @fs.FileKind::Unknown }
  if kind is @fs.FileKind::Unknown {
    return Some("socket not found at \{path}")
  }
  if !(kind is @fs.FileKind::Socket) {
    return Some("\{path} exists but is not a socket")
  }
  let uri = match parse_unix_uri("unix://\{path}") {
    Some(uri) => uri
    None => return Some("\{path} is not a usable unix socket path")
  }
  // `_ping` 不带版本前缀，是全版本 daemon 都有的端点
  let ping = http_over_unix(
    uri.path,
    {
      http_method: "GET",
      path: "/_ping",
      host: uri.host,
      headers: [],
      body: b"",
    },
    timeout_ms,
  ) catch {
    err => {
      // `err.to_string()` 的 `Backend(path, ...)` 形态已经带了 `<path> failed: `，
      // 直接拼在 `<path> is a socket but does not answer: ` 后面会把路径念两遍。
      // 这里把重复的前缀剥掉，只留原因。
      let detail = strip_path_prefix(path, err.to_string())
      return Some("\{path} is a socket but does not answer: \{detail}")
    }
  }
  if ping.status != 200 {
    return Some("\{path} answered _ping with HTTP \{ping.status}")
  }
  None
}

///|
/// 去掉错误文本里重复的 `<path> ` 前缀。
///
/// `DockerCliError` 的 `Show` 会把来源名字拼进文本：
/// `Backend` 是 `<name> failed: <detail>`，`Cancelled` 是 `<name> was cancelled`。
/// 当 `<name>` 恰好就是调用方自己也要打的那条路径时，
/// 外层再补一句 `<path> ...` 就成了「路径念两遍」。
///
/// 两种形态都剥掉，只留原因部分（`connect failed: errno 111`、`was cancelled` …）。
fn strip_path_prefix(path : String, text : String) -> String {
  // `Backend` 形态：`<path> failed: <detail>`，只留 `<detail>`
  let failed = "\{path} failed"
  if text.has_prefix(failed) {
    let rest = text[failed.length():].to_owned()
    return if rest.has_prefix(": ") { rest[2:].to_owned() } else { rest }
  }
  // `Cancelled` 形态：`<path> was cancelled`，整串的重心就是「被取消了」
  let cancelled = "\{path} was cancelled"
  if text.has_prefix(cancelled) {
    return "was cancelled"
  }
  text
}

///|
/// 在 PATH 上找可执行文件，找不到再兜几个常见安装路径。
///
/// 只做「存在 + 可执行」判定，不真的跑 `--version`：
/// 探测本身不应该产生副作用，否则 CI 里一个慢二进制就能拖死启动。
pub async fn resolve_executable(name : String, path : String) -> String? {
  resolve_executable_opts(name, path, allow_fallback=true)
}

///|
/// `resolve_executable` 的带参版本：`allow_fallback=false` 时只认给定 `PATH`，
/// 不去兜 `/usr/bin` 这类系统目录。
///
/// `probe_backends` 在调用方显式传了 `PATH` 时用这个开关——
/// 显式指定 PATH 的意思就是「只在这个范围里找」，再兜系统目录会把
/// 隔离环境（测试、容器）里的判定搅乱：装了 docker 的机器上，
/// 探测就永远失败不了。
async fn resolve_executable_opts(
  name : String,
  path : String,
  allow_fallback~ : Bool,
) -> String? {
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
  if allow_fallback {
    for directory in fallback_directories() {
      let candidate = "\{directory}/\{name}"
      if is_executable_file(candidate) {
        return Some(candidate)
      }
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
