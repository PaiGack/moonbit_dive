///|
/// CLI 后端：把 `docker` / `podman` / `nerdctl` 当黑盒用，只吃它们的
/// `save` / `inspect` 输出。退出码与 stderr 原样带进错误，排查不靠猜。
pub(all) struct DockerCliSource {
  /// 可执行文件绝对路径（或 PATH 上的裸名）
  program : String
  tool : CliTool
  /// 单次调用的超时（毫秒），0 表示不设超时
  timeout_ms : Int32
} derive(Eq, Debug)

///|
pub extend DockerCliSource with Eq::{equal, not_equal}

///|
pub extend DockerCliSource with @debug.Debug::{to_repr}

///|
/// 用固定路径的 CLI 建一个后端。
pub fn DockerCliSource::new(
  program : String,
  tool~ : CliTool = CliTool::Docker,
  timeout_ms~ : Int32 = 0,
) -> DockerCliSource {
  { program, tool, timeout_ms, }
}

///|
impl ImageSource for DockerCliSource with fn inspect(self, reference) {
  guard_reference(reference)
  let (code, stdout, stderr) = run_cli(
    self.program,
    inspect_args(self.tool, reference),
    self.timeout_ms,
    stage="docker inspect \{reference}",
  )
  if code != 0 {
    raise self.inspect_failure(reference, code, stderr)
  }
  parse_inspect(self.tool, stdout, reference)
}

///|
/// CLI 的 `inspect` 失败 → 是「没有这个镜像」还是「工具本身不行」。
///
/// `docker inspect` 对不存在的镜像用 1 退出，且 stderr 里挑明 `No such`；
/// 超时（`code == -1`，不是子进程自己退的）与其它非零退出则一律算
/// 后端故障，别把「工具坏了」误判成「镜像不在」——那会让调用方
/// 拿一次注定失败的拉取盖住真正的错。
///
/// stderr 是英文（docker / podman / nerdctl 都是），所以按文案匹配，
/// 大小写不敏感。三家的原话不一样，都要收：
///
/// - docker：`Error: No such image: nginx:latest`
/// - podman：`Error: nginx:latest: image not known`
/// - nerdctl：`FATA[0000] no such object: nginx:latest`（有时是
///   `content digest ...: not found`）
///
/// 漏掉任何一条的后果不一样且都很坏：把「本地没有」当成「后端坏了」，
/// 就该拉的镜像直接判死；反过来把「后端坏了」当成「本地没有」，
/// 会拿一次注定失败的拉取盖住真正的错（见 `ImageSource::inspect`）。
fn DockerCliSource::inspect_failure(
  self : DockerCliSource,
  reference : String,
  code : Int32,
  stderr : Bytes,
) -> DockerCliError {
  let detail = bytes_to_string(stderr)
  let text = detail.to_lower()
  if code != 0 &&
    (
      text.contains("no such") ||
      text.contains("not found") ||
      text.contains("unable to find") ||
      text.contains("image not known")
    ) {
    ImageNotFound(reference)
  } else {
    Backend(self.program, code, detail)
  }
}

///|
/// CLI 侧的流式 save：stdout 边读边写进 `sink`，内存里不留整段归档。
///
/// 这是 `--from-image` 真正走的那条——`ImageSource::save` 返回 `Bytes`
/// 的形态留给测试与小镜像。用管道而不是 `redirect_to_file` 直连文件，
/// 是因为父进程必须看得见字节：看不见就没法区分「导出很慢但一直在动」
/// 和「卡死了」，而那正是 issue #94 的核心。
pub async fn DockerCliSource::save_into(
  self : DockerCliSource,
  reference : String,
  sink : &ArchiveSink,
) -> Unit raise DockerCliError {
  guard_reference(reference)
  let clock = IdleClock::new()
  let writer = SinkWriter::new(sink)
  let (code, _, stderr, report) = run_capture(
    self.program,
    save_args(self.tool, reference),
    self.timeout_ms,
    sink=StreamTicking(writer, clock),
    clock~,
    stage="docker save \{reference}",
  )
  if code != 0 {
    raise Backend(self.program, code, bytes_to_string(stderr))
  }
  let written = writer.written
  if written == 0 {
    // docker save 对未知镜像会安静地吐一个空 tar；这里当失败处理更实在。
    // 退出码非 0 的情况上面已经带着 stderr 抛过了。
    raise Backend(self.program, 0, "save produced an empty archive")
  }
  on_save_done(report, written)
}

///|
/// `save` 收尾时的旁白：只在调用方装了钩子时才说话。
///
/// 说的是「耗时 + 睡着了多久 + 收了多少字节」，三个数一起才有用：
/// `slept` 是**空闲钟**量到的「一次连续没动静的最长时间」，它比总耗时
/// 更能说明这条链路稳不稳——一个 90 秒的导出里最长空转 2 秒，
/// 与最长空转 28 秒（离判死一步之遥），是完全不同的两件事。
fn on_save_done(report : CliRun, bytes : Int32) -> Unit {
  if save_progress_hook.val is Some(hook) {
    hook(report.elapsed_ms, report.peak_idle_ms, bytes)
  }
}

///|
/// 一次 `save` 收尾的旁白。
///
/// 参数：`elapsed_ms`（这次导出花了多久）、`peak_idle_ms`（其中最长的一段连续静默）、
/// `bytes`（收了多大的归档）。三个数分开报，是因为「花了 90 秒」和
/// 「90 秒里最长静默 28 秒」是两种完全不同的处境：后者离被 30 秒预算判死
/// 只差一步，用户该做的是调大 `--timeout`，而不是怀疑镜像坏了。
pub type OnSaveDone = (Int32, Int32, Int32) -> Unit

///|
/// 一次 `save` 收尾时要不要说话（`--verbose`），由调用方在 main 里装。
///
/// 用全局钩子而不是给整条 `save_into` 的签名加参数：`save_into` 是
/// `ArchiveSink` 那条链路上的中间层，为了打一行日志把 `verbose` 从 CLI
/// 参数一路穿过 `source` / `backend` / `engine` 三个包，代价远大于收益。
/// 钩子是「进程级行为」（要不要打日志），不是「这次调用的语义」。
pub let save_progress_hook : Ref[OnSaveDone?] = Ref(None)

///|
/// `ArchiveSink` → `@io.Writer` 的适配层，顺便记下写了多少字节。
///
/// 需要一个中间类型而不是直接 `impl @io.Writer for ArchiveSink`：
/// MoonBit 不允许给 trait 直接写 impl，而这里想要的恰恰是
/// 「任意 sink 都能当 writer 用」。
priv struct SinkWriter {
  sink : &ArchiveSink
  mut written : Int32
}

///|
fn SinkWriter::new(sink : &ArchiveSink) -> SinkWriter {
  { sink, written: 0, }
}

///|
impl @io.Writer for SinkWriter with fn write_once(
  self,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  self.sink.write(buf[offset:offset + len].to_owned())
  self.written = self.written + len
  len
}

///|
/// 小块推送时的块大小。
///
/// `SinkWriter` 本身是按块被喂的（`read_to_bytes` 一次给 64KB），这里再切一刀
/// 不是为了节流，而是为了让「写盘 / 算哈希」这种**慢 sink** 也能按小块推进：
/// 下游 `progress::TeeSink` 要拿块大小算进度，块太粗（几百 MB 的层一次给完）
/// 就等于没有进度。8KB 与常见 IO 缓冲同量级，代价可以忽略。
let save_push_chunk : Int32 = 8192

///|
/// 把一个 writer 包成 [`ArchiveSink`]：写进去的字节原样交给它，并**分小块**推。
///
/// 分块的意义见 [`save_push_chunk`]；它同时保证了「推一块 = 一次心跳」——
/// 大块一次塞进去，中间的等待在空闲钟眼里就是一个空洞。
pub fn writer_sink(writer : &@io.Writer) -> &ArchiveSink {
  PushSink::{ writer, }
}

///|
/// [`writer_sink`] 的实现：只做「切块 + 转交」。
///
/// 不用闭包类型是为了能 `impl` 一个 `pub(open) trait`（trait 需要具名实现者），
/// 顺带也不用管闭包捕获可变状态的那堆约束。
struct PushSink {
  writer : &@io.Writer
}

///|
impl ArchiveSink for PushSink with fn write(self, bytes) {
  let mut offset = 0
  let total = bytes.length()
  while offset < total {
    let take = @cmp.minimum(save_push_chunk, total - offset)
    let slice = bytes[offset:offset + take].to_owned()
    self.writer.write(slice) catch {
      err => raise Backend("write", -1, err.to_string())
    }
    offset = offset + take
  }
}

///|
pub extend PushSink with ArchiveSink::{write}

///|
/// 让 `run_cli_to_file` 的流式逻辑也吃 `@io.Writer`：同一个循环、
/// 同一个空闲计时，只是终点从文件换成任意 sink。
pub async fn run_cli_to_writer(
  program : String,
  args : Array[String],
  writer : &@io.Writer,
  timeout_ms : Int32,
  stage~ : String = "",
) -> Unit raise DockerCliError {
  let clock = IdleClock::new()
  let (code, _, stderr, _) = run_capture(
    program,
    args,
    timeout_ms,
    sink=Stream(writer),
    clock~,
    stage~,
  )
  if code != 0 {
    raise Backend(program, code, bytes_to_string(stderr))
  }
}

///|
impl ImageSource for DockerCliSource with fn save(self, reference) {
  guard_reference(reference)
  let (code, stdout, stderr) = run_cli(
    self.program,
    save_args(self.tool, reference),
    self.timeout_ms,
    stage="docker save \{reference}",
  )
  if code != 0 {
    raise Backend(self.program, code, bytes_to_string(stderr))
  }
  if stdout.is_empty() {
    // docker save 对未知镜像会安静地吐一个空 tar；这里当失败处理更实在
    raise Backend(self.program, code, "save produced an empty archive")
  }
  stdout
}

///|
impl ImageSource for DockerCliSource with fn pull(self, reference) {
  guard_reference(reference)
  let (code, _stdout, stderr) = run_cli(
    self.program,
    pull_args(reference),
    self.timeout_ms,
    stage="docker pull \{reference}",
  )
  if code != 0 {
    raise Backend(self.program, code, bytes_to_string(stderr))
  }
}

///|
/// `docker save` / `podman save` / `nerdctl save` 的参数形态。
///
/// docker 与 nerdctl 的 `save` 默认输出 **docker-archive**（`manifest.json` +
/// `<config>.json` + `<id>/layer.tar`），正是 P2 吃的格式，不用加任何参数。
///
/// podman 不行：默认 `--format oci-archive`，解出来是一个 bloB 目录，
/// 没有 `manifest.json`——P2 拿到只会报「不是可读的镜像归档」。
/// 必须显式 `--format docker-archive` 拉齐。
///
/// `-o` 落盘那条路径（`save_to_file`）同样走这个函数，所以这里改一处
/// 两条路径都跟着改——podman 的格式不显式指定，落盘出来同样是 oci-archive。
pub fn save_args(tool : CliTool, reference : String) -> Array[String] {
  match tool {
    Docker | Nerdctl => ["save", reference]
    Podman => ["save", "--format", "docker-archive", reference]
  }
}

///|
/// `docker pull` / `podman pull` / `nerdctl pull` 参数形态一致：
/// 镜像引用是唯一的位置参数，没有工具差异（与 `save` / `inspect` 不同）。
///
/// 进度打到 stdout（docker 还要 TTY 才好看），这里不看进度、只认退出码。
///
/// 参数一致、失败文案不一致：拉取失败一律是 `Backend`（带 stderr），
/// 不翻成 `ImageNotFound`。这条区分由 `inspect` 负责——
/// `inspect` 说本地没有才是「本地没有」，网络层说 `manifest unknown`
/// 是 registry 那边的事，翻成 `ImageNotFound` 会让调用方以为
/// 「再拉一次就好」，而它刚刚才拉过。
pub fn pull_args(reference : String) -> Array[String] {
  ["pull", reference]
}

///|
/// `inspect` 的参数形态。docker / nerdctl 默认就吐 JSON 数组；
/// podman 需要显式 `--format json`，否则是 Go 模板渲染的表格。
///
/// 三家的 JSON 字段是同一套（`Id` / `Architecture` / `Os` / `Size` /
/// `VirtualSize`），所以 `parse_inspect` 不用分工具——差异只在参数上。
pub fn inspect_args(tool : CliTool, reference : String) -> Array[String] {
  match tool {
    Docker | Nerdctl => ["inspect", reference]
    Podman => ["inspect", "--format", "json", reference]
  }
}

///|
/// 镜像名不能是空的。
fn guard_reference(reference : String) -> Unit raise DockerCliError {
  if reference.trim().is_empty() {
    raise InvalidReference("image reference is empty")
  }
}

///|
pub extend DockerCliSource with ImageSource::{inspect, save, pull}

///|
/// 把 `save` 的结果直接落到文件，中途不把整段归档拼进内存。
///
/// 大镜像走这条路：`ImageSource::save` 返回 `Bytes` 的形态适合小镜像与测试，
/// 几百 MB 的层用这个入口。返回写入的字节数。
pub async fn DockerCliSource::save_to_file(
  self : DockerCliSource,
  reference : String,
  output_path : String,
) -> Int32 raise DockerCliError {
  guard_reference(reference)
  let (code, written) = run_cli_to_file(
    self.program,
    save_args(self.tool, reference),
    output_path,
    self.timeout_ms,
    stage="docker save \{reference}",
  )
  if code != 0 {
    raise Backend(self.program, code, "save failed")
  }
  if written == 0 {
    raise Backend(self.program, code, "save produced an empty archive")
  }
  written
}
