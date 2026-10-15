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
  let (archive, _resolved) = fetch_archive_with_backends(
    reference,
    candidates,
    env,
    timeout_ms~,
    pull_if_missing~,
  )
  archive
}

///|
/// 单条后端上的「本地没有就先拉」策略。`fetch_archive` 一族走的是
/// `save_or_pull_across_backends`（多一条后端会换路），这里保留单条入口
/// 给「就认这一个后端」的调用方与测试。
///
/// 触发条件是 **`inspect` 明确说本地没有**（`ImageNotFound`），
/// 不是「`save` 失败了就拉」：`save` 的失败面太宽（daemon 卡住、权限、磁盘满），
/// 一律当成「镜像不在」会拿一次不必要的网络拉取盖住真正的错误。
/// `inspect` 给别的错说明**这条路本身不行**，该做的是换路，不是拉。
pub async fn save_maybe_pulling(
  backend : ImageBackend,
  reference : String,
  pull_if_missing~ : Bool = false,
) -> Bytes raise DockerCliError {
  save_or_pull_once(backend, reference, pull_if_missing~)
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
  fetch_archive_with_backends(
    reference,
    candidates,
    env,
    timeout_ms~,
    pull_if_missing~,
  )
}

///|
/// 取归档的公共实现：先把候选列表做成一条**有退路**的后端序列，
/// 再顺着它取；一条路取不到就换下一条。
///
/// 这是 issue #42 的第二层。第一层（探测时发个有超时的 `_ping`）只挡得住
/// 「socket 根本不通」；挡不住「socket 通、`_ping` 答，但真去
/// `GET /images/{name}/get` 时才发现对端没有这个镜像」——CNB 这类环境里
/// `/var/run/docker.sock` 是外层转发进来的，正是这个样子。要分清
/// 「这条路推不动」，只有真走一趟取归档。
async fn fetch_archive_with_backends(
  reference : String,
  candidates : Array[BackendCandidate],
  env : Map[String, String],
  timeout_ms~ : Int32,
  pull_if_missing~ : Bool,
) -> (Bytes, ResolvedBackend) raise DockerCliError {
  let resolved = resolve_backend(candidates, env, timeout_ms~)
  let backends = backend_chain(candidates, resolved, env, timeout_ms~)
  let archive = save_or_pull_across_backends(
    backends,
    0,
    reference,
    pull_if_missing~,
  )
  (archive, resolved)
}

///|
/// 「一条路取不到就换下一条」：从 `index` 开始顺着后端序列往下试。
///
/// 每一条上的动作都是同一套（顺序与原版 dive 对齐）：
///
/// 1. `inspect`——说本地有就直接 `save`，不再上网；
/// 2. 说本地没有且 `pull_if_missing`——`pull` 一次再 `save`；
/// 3. 这一步整条都失败——记下原因，换下一条路，直到序列走完。
///
/// `inspect` 的失败要分清：`ImageNotFound` 才是「本地没有」，
/// 其余（超时、连不上、名字非法）是「这条路本身不行」——后者直接换路，
/// 不拿一次注定失败的拉取盖住真原因。
///
/// 失败原因不吞：候选全试完时把最后一条的原因报出来，
/// 用户要的是「为什么都不行」，不是一句「取不到」。
pub async fn save_or_pull_across_backends(
  backends : Array[ImageBackend],
  index : Int32,
  reference : String,
  pull_if_missing~ : Bool = false,
) -> Bytes raise DockerCliError {
  let attempts : Array[String] = []
  let mut first : DockerCliError? = None
  let mut position = index
  let count = backends.length()
  while position < count {
    let backend = backends[position]
    let outcome : Result[Bytes, DockerCliError] = try
      save_or_pull_once(backend, reference, pull_if_missing~)
    catch {
      err => Err(err)
    } noraise {
      archive => Ok(archive)
    }
    match outcome {
      Ok(archive) => return archive
      // 这条路走不通：记下原因，接着试下一条
      Err(err) => {
        attempts.push("  \{backend} — \{err.to_string()}")
        if first is None {
          first = Some(err)
        }
      }
    }
    position = position + 1
  }
  // 报**第一条**（也就是被选中的那条后端）的原因，不是最后一条。
  //
  // 「最后一条」几乎总是候选序列尾巴上那些够不着的兜底项：DOCKER_HOST 指的
  // socket 超时之后，序列还会去敲不存在的 `/var/run/docker.sock`，它的
  // ENOENT 会盖住真正的超时。用户看到一句「/var/run/docker.sock failed:
  // connect failed: errno 2」，既不像超时、也不是他实际用的后端——
  // 只能对着它猜。
  //
  // 错误**类型**保持第一条原样（超时仍是 `Cancelled`、后端故障仍是 `Backend`），
  // 只是把「每条后端分别怎么了」并进 detail：调用方按类型判断，
  // 读日志的人拿到完整的故事。
  match first {
    Some(err) => raise with_attempts(err, attempts)
    None => raise NoBackend("no backend available to fetch \{reference}")
  }
}

///|
/// 把「每条后端分别怎么了」并进主错误的 detail，类型不变。
fn with_attempts(
  err : DockerCliError,
  attempts : Array[String],
) -> DockerCliError {
  if attempts.length() <= 1 {
    // 只有一条路时主错误已经把话说完了，再加一遍是噪声
    return err
  }
  let trail = "\nbackends tried:\n" + attempts.join("\n")
  // 只往 `Show` 会把 detail 原样放在结尾的变体上追加。
  // `Cancelled(name)` 会渲染成「<name> was cancelled」、
  // `ExecutableNotFound(name)` 渲染成「executable not found: <name>」，
  // 往它们的 payload 上拼 trail 会把句子拼坏，故只保留原样——
  // 这两种情况的标题已经说清楚了，逐条原因留给 `--verbose`。
  match err {
    NoBackend(detail) => NoBackend(detail + trail)
    Backend(name, code, detail) => Backend(name, code, detail + trail)
    Archive(detail) => Archive(detail + trail)
    InvalidReference(detail) => InvalidReference(detail + trail)
    ImageNotFound(reference) => ImageNotFound(reference + trail)
    _ => err
  }
}

///|
/// 在**一条**后端上取归档：先问本地有没有，缺了就拉，最后取。
///
/// 这是原版 dive 的顺序，也是这里的契约：`inspect` 说本地有就绝不上网。
/// `inspect` 的「没有」与「这条路不行」由 `ImageNotFound` 分开，
/// 见 `is_missing_image`。
async fn save_or_pull_once(
  backend : ImageBackend,
  reference : String,
  pull_if_missing~ : Bool,
) -> Bytes raise DockerCliError {
  if pull_if_missing && !image_is_local(backend, reference) {
    ImageSource::pull(backend, reference)
  }
  ImageSource::save(backend, reference)
}

///|
/// 本地有没有这个镜像。
///
/// `ImageNotFound` 是后端给的确定答案（Engine 404 / CLI 的 `No such image`），
/// 那才算「没有」。其余失败（超时、连不上、名字非法）一律上抛——
/// 把「不确定」当成「没有」会去拉一次，然后拿网络层的错误盖住真原因，
/// 而真原因往往是「这条路本身不行」，该做的是换一条路。
async fn image_is_local(
  backend : ImageBackend,
  reference : String,
) -> Bool raise DockerCliError {
  let inspected : Result[ImageInfo, DockerCliError] = try
    ImageSource::inspect(backend, reference)
  catch {
    err => Err(err)
  } noraise {
    info => Ok(info)
  }
  match inspected {
    Ok(_) => true
    Err(err) =>
      match err {
        ImageNotFound(_) => false
        _ => raise err
      }
  }
}

///|
/// 候选列表 + 探测结果 → 可直接调用的后端序列，**从选中的那条开始**。
///
/// 「从选中的那条开始往后走」本身就是「这条路推不动就换下一条」：
/// CNB 这类环境里 socket 由外层转发进来，探测阶段 `_ping` 会答（判它可用），
/// 可真去取归档时才发现对端没有那个镜像——这时序列后面还有 PATH 上的
/// docker。反过来 `DOCKER_CLI` 指的 docker 推不动时，后面也还留着 socket。
/// 两种方向不用分别写，一条按探测顺序排的序列就够。
///
/// 建不出来的候选（socket 路径拼不出 URI、可执行文件不在）直接跳过：
/// 它们连「试一次」的机会都不该有。
pub async fn backend_chain(
  candidates : Array[BackendCandidate],
  resolved : ResolvedBackend,
  env : Map[String, String],
  timeout_ms~ : Int32,
) -> Array[ImageBackend] noraise {
  let start = if resolved.probed.index < 0 { 0 } else { resolved.probed.index }
  let backends : Array[ImageBackend] = []
  for index in start..<candidates.length() {
    match build_backend(candidates[index], env, timeout_ms~) {
      Some(backend) => backends.push(backend)
      None => ()
    }
  }
  backends
}

///|
/// 单个候选 → 可直接调用的后端。socket 路径拼不出 URI、可执行文件不在时给 `None`。
async fn build_backend(
  candidate : BackendCandidate,
  env : Map[String, String],
  timeout_ms~ : Int32,
) -> ImageBackend? noraise {
  match candidate {
    Socket(path) => {
      let uri = match parse_unix_uri("unix://\{path}") {
        Some(uri) => uri
        None => return None
      }
      Some(ImageBackend::Engine(EngineSource::new(uri, timeout_ms~)))
    }
    Program(program, tool) =>
      Some(ImageBackend::Cli(DockerCliSource::new(program, tool~, timeout_ms~)))
    Cli(tool) => {
      let name = Show::to_string(tool)
      let resolved : String? = try
        resolve_executable(name, path_of(env))
      catch {
        _ => None
      } noraise {
        program => program
      }
      match resolved {
        Some(path) =>
          Some(
            ImageBackend::Cli(DockerCliSource::new(path, tool~, timeout_ms~)),
          )
        None => None
      }
    }
  }
}

///|
pub extend ImageBackend with ImageSource::{inspect, save, pull}
