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
/// 按候选顺序探测出第一个可用后端，并构造好对应的 `ImageBackend`。
///
/// 一个都探不到时抛 `NoBackend`，错误信息里带上每个候选的失败原因——
/// issue #17 明确要求「无 daemon 环境下有明确错误与提示，不 panic」。
pub async fn resolve_backend(
  candidates : Array[BackendCandidate],
  env : Map[String, String],
  timeout_ms~ : Int32 = 0,
) -> ResolvedBackend raise DockerCliError {
  let probed = probe_backends(candidates, env) catch {
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
  timeout_ms~ : Int32 = 0,
) -> Bytes raise DockerCliError {
  let candidates = default_candidates(env)
  let resolved = resolve_backend(candidates, env, timeout_ms~)
  ImageSource::save(resolved.backend, reference)
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
  timeout_ms~ : Int32 = 0,
  candidates? : Array[BackendCandidate],
) -> (Bytes, ResolvedBackend) raise DockerCliError {
  let candidates = match candidates {
    Some(candidates) => candidates
    None => default_candidates(env)
  }
  let resolved = resolve_backend(candidates, env, timeout_ms~)
  let archive = ImageSource::save(resolved.backend, reference)
  (archive, resolved)
}

///|
pub extend ImageBackend with ImageSource::{inspect, save}
