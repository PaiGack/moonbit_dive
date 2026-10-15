///|
/// 一条「镜像名 → 本地归档」的通路。issue #17 只要两种实现：
/// CLI 包装（`DockerCliSource`）与 Engine HTTP（`EngineSource`，见 engine.mbt）。
pub(open) trait ImageSource {
  /// 看本地有没有这个镜像。
  ///
  /// 「后端答了没有」必须与「后端本身用不了」分开：前者（Engine 404）
  /// 抛 `ImageNotFound`，调用方据此走「缺了就拉」；后者（连不上、超时、
  /// 名字非法）抛别的错。混成一个错误，就只能靠猜——猜错的代价是
  /// 把一次注定失败的网络拉取当成「镜像不在」的证明。
  async fn inspect(Self, String) -> ImageInfo raise DockerCliError
  async fn save(Self, String) -> Bytes raise DockerCliError
  /// 把镜像拉到本地。本地已有（或拉取过程判定为「已存在」）时是空操作。
  ///
  /// 单独成一个方法而不是折进 `save`：`save` 的契约是「本地必须已有」，
  /// 拉了才 save 属于调用方（`cmd/main --from-image`）的策略，
  /// 包一层 `pull` 让这个策略显式、可关、可单独测。
  async fn pull(Self, String) -> Unit raise DockerCliError
}

///|
/// 镜像元信息。字段刻意与 `docker inspect` 的输出对齐，
/// 缺字段留空而不是报错——inspect 只是给用户看的旁证，不是分析输入。
pub(all) struct ImageInfo {
  /// 镜像 ID，形如 `sha256:...`
  id : String
  /// 镜像引用，形如 `nginx:latest`
  reference : String
  /// `amd64` / `arm64` ...
  architecture : String
  /// `linux` / `windows` ...
  os : String
  /// `docker save` 出来的归档字节数；inspect 拿不到时为 0
  size : Int32
  /// 镜像内所有层的累计大小（uncompressed）
  virtual_size : Int32
} derive(Eq, Debug)

///|
pub extend ImageInfo with Eq::{equal, not_equal}

///|
pub extend ImageInfo with @debug.Debug::{to_repr}

///|
/// 后端种类。值直接当可执行文件名用（Engine 除外）。
pub(all) enum CliTool {
  Docker
  Podman
  Nerdctl
} derive(Eq, Debug)

///|
pub extend CliTool with Eq::{equal, not_equal}

///|
pub extend CliTool with @debug.Debug::{to_repr}

///|
impl Show for CliTool with fn to_string(self) {
  match self {
    Docker => "docker"
    Podman => "podman"
    Nerdctl => "nerdctl"
  }
}

///|
pub extend CliTool with Show::{to_string, output}

///|
/// 探测顺序里的一项。
pub(all) enum BackendCandidate {
  /// `DOCKER_HOST=unix://...` 显式指定的 socket
  Socket(String)
  /// CLI 可执行文件，按 `CliTool` 的名字去 PATH 上找
  Cli(CliTool)
  /// `DOCKER_CLI` 显式指定的可执行文件路径。
  ///
  /// 单独成一个变体而不是复写 `Cli`：`DOCKER_CLI=/opt/bin/docker` 的语义是
  /// 「就用这个文件」，不是「去 PATH 上找叫 docker 的东西」。把它折回
  /// `Cli(tool)` 会让那个路径被丢掉——用户写死的程序根本不会被调用。
  Program(String, CliTool)
} derive(Eq, Debug)

///|
pub extend BackendCandidate with Eq::{equal, not_equal}

///|
pub extend BackendCandidate with @debug.Debug::{to_repr}

///|
impl Show for BackendCandidate with fn to_string(self) {
  match self {
    Socket(path) => "unix://\{path}"
    Cli(tool) => "\{tool}"
    Program(path, _) => path
  }
}

///|
pub extend BackendCandidate with Show::{to_string, output}

///|
/// 探测结果：选中了谁、为什么。
///
/// `reason` 是给人看的排查线索，issue #17 明确要求「探测结果要能打印出来」。
pub(all) struct ProbedBackend {
  /// 选中项在候选列表里的下标，-1 表示没选中
  index : Int32
  candidate : BackendCandidate?
  /// 依次尝过哪些候选、各自为什么没成
  attempts : Array[BackendAttempt]
} derive(Eq, Debug)

///|
pub extend ProbedBackend with Eq::{equal, not_equal}

///|
pub extend ProbedBackend with @debug.Debug::{to_repr}

///|
/// 单个候选的探测记录。
pub(all) struct BackendAttempt {
  candidate : BackendCandidate
  ok : Bool
  reason : String
} derive(Eq, Debug)

///|
pub extend BackendAttempt with Eq::{equal, not_equal}

///|
pub extend BackendAttempt with @debug.Debug::{to_repr}

///|
impl Show for BackendAttempt with fn to_string(self) {
  let mark = if self.ok { "ok" } else { "no" }
  "[\{mark}] \{Show::to_string(self.candidate)}: \{self.reason}"
}

///|
pub extend BackendAttempt with Show::{to_string, output}

///|
/// 探测记录的人类可读输出，一行一个候选。
pub fn describe_backends(probed : ProbedBackend) -> String {
  let lines = []
  for attempt in probed.attempts {
    lines.push(Show::to_string(attempt))
  }
  lines.join("\n")
}
