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
impl ImageSource for DockerCliSource with fn save(self, reference) {
  guard_reference(reference)
  let (code, stdout, stderr) = run_cli(
    self.program,
    save_args(self.tool, reference),
    self.timeout_ms,
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
  )
  if code != 0 {
    raise Backend(self.program, code, "save failed")
  }
  if written == 0 {
    raise Backend(self.program, code, "save produced an empty archive")
  }
  written
}
