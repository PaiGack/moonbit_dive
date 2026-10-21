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
  /// 拉了才 save 属于调用方（`cmd/main` 的镜像引用档）的策略，
  /// 包一层 `pull` 让这个策略显式、可关、可单独测。
  async fn pull(Self, String) -> Unit raise DockerCliError
}

///|
/// 归档字节的去向：一条后端把 `save` 的流倒进这里。
///
/// 与 `ImageSource::save -> Bytes` 并存，是因为两条路各有各的用处：
/// 返回 `Bytes` 的形态适合小镜像与测试（一行就能断言），
/// 而镜像引用面对的是几百 MB 的层——全量驻留内存既浪费也不稳。
/// 这里的 `write` 是**一遍过**的流式接口，实现方不许为了先算长度而缓冲。
pub(open) trait ArchiveSink {
  /// 收下一段归档字节。**必须**是 async：落盘那一路的 `@fs.File::write`
  /// 就是 async 的，用同步签名会把整条流式路径堵死。
  async fn write(Self, Bytes) -> Unit raise DockerCliError
}

///|
/// 一个「边取边落盘」的临时归档。
///
/// 为什么不是 `Bytes`：issue #94 里 `docker save` 对着一个已经拉到本地的镜像
/// 闷头导出，几十秒一个字节都不吐。要是取归档的路径是「先在内存里拼完
/// 再交出去」，那就只剩两条烂路——为等这个 `Bytes` 把内存撑爆，
/// 或在某处设一个总时长上限把正常的慢导出砍掉。落到文件之后，
/// 字节一出来就进盘，超时只用于管「真的没动静」。
///
/// 生命周期由调用方用 `errdefer temp.discard()` 管住。
pub(all) struct TempArchive {
  path : String
  mut file : @fs.File
}

///|
/// 手写 `Debug`：`@fs.File` 没有 `Debug`，而这里想看的只有路径。
pub impl @debug.Debug for TempArchive with fn to_repr(self) {
  @debug.Repr::string("TempArchive(\{self.path})")
}

///|
pub extend TempArchive with @debug.Debug::{to_repr}

///|
pub async fn TempArchive::create() -> TempArchive raise DockerCliError {
  let dir = @fs.tmpdir(prefix="dive-archive-") catch {
    err => raise Backend("tmp", -1, "cannot make a temp dir: \{err}")
  }
  let path = "\{dir}/archive.tar"
  let file = open_for_write(path)
  { path, file, }
}

///|
async fn open_for_write(path : String) -> @fs.File raise DockerCliError {
  @fs.open(
    path,
    mode=@fs.WriteOnly,
    create_mode=@fs.CreateMode::CreateOrTruncate,
  ) catch {
    err => raise Backend("tmp", -1, "cannot open \{path}: \{err}")
  }
}

///|
/// 清空已写入的内容，从 0 开始重来。
///
/// 换后端时必须调用：上一条后端可能已经写了半截（`Cancelled` 正好落在
/// 700MB 的地方），不清掉的话下一条会接着往后追加，最后拼出一个
/// 「前一半是 A、后一半是 B」的归档——它甚至能读出 tar 开头的文件名，
/// 错得很深。
pub async fn TempArchive::rewind(
  self : TempArchive,
) -> Unit raise DockerCliError {
  self.file.close()
  self.file = open_for_write(self.path)
}

///|
pub impl ArchiveSink for TempArchive with fn write(self, bytes) {
  self.file.write(bytes) catch {
    err => raise Backend("tmp", -1, "cannot write \{self.path}: \{err}")
  }
}

///|
pub extend TempArchive with ArchiveSink::{write}

///|
/// 把临时归档整体读回来。这是**唯一**需要让归档进内存的一步，
/// 因为下游 `ImageSource::from_tar_bytes` 吃的是字节。
pub async fn TempArchive::read_back(
  self : TempArchive,
) -> Bytes raise DockerCliError {
  self.file.close()
  @fs.read_file(self.path).binary() catch {
    err => raise Backend("tmp", -1, "cannot read \{self.path}: \{err}")
  }
}

///|
/// 收尾：关句柄、删文件、删临时目录。成功与失败路径都要调。
pub async fn TempArchive::discard(self : TempArchive) -> Unit noraise {
  self.file.close()
  @fs.remove(self.path) catch {
    _ => ()
  }
  @fs.rmdir(dir_of(self.path), recursive=true) catch {
    _ => ()
  }
}

///|
fn dir_of(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => path[:index].to_owned()
    None => path
  }
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
