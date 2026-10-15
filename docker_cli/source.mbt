///|
/// 一个「镜像名 → 本地归档」的通路。CLI 后端与 Engine 后端都实现 `ImageSource`，
/// 这个枚举让调用方在两者之间切换而不必关心具体类型。
pub(all) enum ImageBackend {
  /// 包装 docker / podman / nerdctl 可执行文件
  Cli(DockerCliSource)
  /// 直连 Docker Engine 的 unix socket
  Engine(EngineSource)
} derive(Debug)

///|
pub extend ImageBackend with @debug.Debug::{to_repr}

///|
impl ImageSource for ImageBackend with fn inspect(self, reference) {
  match self {
    Cli(source) => ImageSource::inspect(source, reference)
    Engine(source) => ImageSource::inspect(source, reference)
  }
}

///|
impl ImageSource for ImageBackend with fn save(self, reference) {
  match self {
    Cli(source) => ImageSource::save(source, reference)
    Engine(source) => ImageSource::save(source, reference)
  }
}

///|
impl ImageSource for ImageBackend with fn pull(self, reference) {
  match self {
    Cli(source) => ImageSource::pull(source, reference)
    Engine(source) => ImageSource::pull(source, reference)
  }
}

///|
impl Show for ImageBackend with fn to_string(self) {
  match self {
    Cli(source) => "cli:\{source.program}"
    Engine(source) => "engine:unix://\{source.uri.path}"
  }
}

///|
pub extend ImageBackend with Show::{to_string, output}

///|
/// 探测 + 构造后的结果：选中的后端，以及完整的探测记录。
pub(all) struct ResolvedBackend {
  backend : ImageBackend
  /// 探测过程，`describe_backends` 可以直接打印
  probed : ProbedBackend
} derive(Debug)

///|
pub extend ResolvedBackend with @debug.Debug::{to_repr}

///|
/// 一次后端调用的默认超时（毫秒）。
///
/// 不能是 0（无超时）：`/var/run/docker.sock` 在 CNB 这类环境里是**转发进来**的，
/// socket 文件在、`connect` 也能立刻成功，但对端（真正的 daemon）可能根本不通。
/// 没有超时的话，请求会停在「等状态行」上**永远不返回**，用户看到的是
/// 「完全没有任何输出」——排查成本远超一次明确的超时错误。
///
/// 30 秒是「够慢的拉取起步、又不至于让人以为卡死」的折中；
/// 真要长时间拉大镜像，调用方显式传更大的 `timeout_ms`。
pub let default_timeout_ms : Int32 = 30000

///|
/// 按候选顺序探测出第一个可用后端，并构造好对应的 `ImageBackend`。
///
/// 一个都探不到时抛 `NoBackend`，错误信息里带上每个候选的失败原因——
/// issue #17 明确要求「无 daemon 环境下有明确错误与提示，不 panic」。
pub async fn resolve_backend(
  candidates : Array[BackendCandidate],
  env : Map[String, String],
  timeout_ms~ : Int32 = default_timeout_ms,
) -> ResolvedBackend raise DockerCliError {
  let probed = probe_backends(candidates, env, timeout_ms~) catch {
    err => raise NoBackend("backend probing failed: \{err}")
  }
  match probed.candidate {
    None => raise NoBackend(describe_backends(probed))
    Some(Socket(path)) => {
      let uri = match parse_unix_uri("unix://\{path}") {
        Some(uri) => uri
        None => raise NoBackend("unusable unix socket: \{path}")
      }
      {
        backend: ImageBackend::Engine(EngineSource::new(uri, timeout_ms~)),
        probed,
      }
    }
    // `Program` 是 `DOCKER_CLI` 写死的路径，直接用；`Cli` 才去 PATH 上重解析。
    // 两者分开是为了不让「探测用的名字」和「调用用的名字」再对不上一次。
    Some(BackendCandidate::Program(program, tool)) =>
      {
        backend: ImageBackend::Cli(
          DockerCliSource::new(program, tool~, timeout_ms~),
        ),
        probed,
      }
    Some(BackendCandidate::Cli(tool)) => {
      let name = Show::to_string(tool)
      let program = match
        (resolve_executable(name, path_of(env)) catch { _ => None }) {
        Some(path) => path
        None => raise NoBackend("\\{name} disappeared between probing and use")
      }
      {
        backend: ImageBackend::Cli(
          DockerCliSource::new(program, tool~, timeout_ms~),
        ),
        probed,
      }
    }
  }
}

///|
/// 探测用哪个 `PATH`：显式传进来的 `env` 优先，缺省回落到进程环境。
fn path_of(env : Map[String, String]) -> String {
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
/// 从进程环境变量里取 `DOCKER_HOST` / `DOCKER_CLI` / `PATH` 等。
/// 显式传入 `env` 而不是直接读全局，测试才能钉住探测顺序。
pub fn process_env() -> Map[String, String] {
  @env.get_env_vars()
}

///|
/// 一步到位：镜像名 → 归档字节。
///
/// `DOCKER_CLI` / `DOCKER_HOST` 走 `env`；默认候选顺序见 `default_candidates`。
pub async fn fetch_archive(
  reference : String,
  env~ : Map[String, String] = process_env(),
  timeout_ms~ : Int32 = default_timeout_ms,
  pull_if_missing~ : Bool = false,
) -> Bytes raise DockerCliError {
  let candidates = default_candidates(env)
  let resolved = resolve_backend(candidates, env, timeout_ms~)
  let archive = save_maybe_pulling(
    resolved.backend,
    reference,
    pull_if_missing~,
  )
  archive
}

///|
/// 「本地没有就先拉」的策略，`fetch_archive` 与 `fetch_archive_verbose` 共用。
///
/// 触发条件是 **`inspect` 说本地没有**，不是「`save` 失败了就拉」：
/// `save` 的失败面太宽（daemon 卡住、权限、磁盘满），
/// 一律当成「镜像不在」会拿一次不必要的网络拉取盖住真正的错误，
/// 排查时看到的是 pull 的报错而不是最初那个。
pub async fn save_maybe_pulling(
  backend : ImageBackend,
  reference : String,
  pull_if_missing~ : Bool = false,
) -> Bytes raise DockerCliError {
  if pull_if_missing && !image_is_local(backend, reference) {
    ImageSource::pull(backend, reference)
  }
  ImageSource::save(backend, reference)
}

///|
/// 本地有没有这个镜像。拿不到确定答案时返回 `false`（即「当作没有」）。
///
/// `inspect` 失败的原因分得没那么细：daemon 挂了、socket 权限不对、
/// 名字不合法都会落到同一个 catch 里。这时候认成「本地没有」去拉一次，
/// 拉不动的话错误信息里会有 pull 的具体原因，比 inspect 的泛泛报错更有用；
/// 拉得动就说明本地确实没有。反过来把「不确定」当「有」，
/// 用户会拿到一个说不清为什么失败的 `save`。
async fn image_is_local(
  backend : ImageBackend,
  reference : String,
) -> Bool noraise {
  let found : Bool = try
    ImageSource::inspect(backend, reference) |> ignore
  catch {
    _ => false
  } noraise {
    _ => true
  }
  found
}

///|
/// 一步到位：镜像名 → 归档字节 + 探测记录，便于 CLI 打印「用了哪个后端、为什么」。
///
/// `candidates` 不传时走 `default_candidates(env)`。要钉住探测范围的调用方
/// （测试、以及想自定义降级顺序的场景）可以显式传一个候选列表——
/// `default_candidates` 总会把 `/var/run/docker.sock` 塞进去，
/// 装了真 daemon 的机器上就轮不到 CLI 后端，测试会变成「取决于机器装没装 docker」。
pub async fn fetch_archive_verbose(
  reference : String,
  env~ : Map[String, String] = process_env(),
  timeout_ms~ : Int32 = default_timeout_ms,
  candidates? : Array[BackendCandidate],
  pull_if_missing~ : Bool = false,
) -> (Bytes, ResolvedBackend) raise DockerCliError {
  let candidates = match candidates {
    Some(candidates) => candidates
    None => default_candidates(env)
  }
  let resolved = resolve_backend(candidates, env, timeout_ms~)
  let archive = save_maybe_pulling(
    resolved.backend,
    reference,
    pull_if_missing~,
  )
  (archive, resolved)
}

///|
pub extend ImageBackend with ImageSource::{inspect, save, pull}
