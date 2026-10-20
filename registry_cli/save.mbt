///|
/// `dive save` 的全部参数。名字对齐 `docker save` 的使用习惯，
/// 但**没有** `-o` 之外任何需要 daemon 的东西。
pub(all) struct SaveRequest {
  reference : String
  /// 输出路径；OCI layout 时是目录
  output : String
  format : ArchiveFormat
  platform : String?
  insecure : Bool
  token : String?
  /// 拉取进度（写 stderr / 画进度条由调用方决定）
  on_progress : ((PullEvent) -> Unit)?
  /// 每次报完进度后「立刻画一下」的钩子，见 `PullOptions::on_tick`
  on_tick : (() -> Unit noraise)?
  /// 同时在途的层数（1 = 逐层串行），见 `PullOptions::concurrency`
  jobs : Int32
}

///|
pub fn SaveRequest::new(
  reference~ : String,
  output~ : String,
  format~ : ArchiveFormat = DockerArchive,
  platform~ : String? = None,
  insecure~ : Bool = false,
  token~ : String? = None,
  on_progress~ : ((PullEvent) -> Unit)? = None,
  on_tick~ : (() -> Unit noraise)? = None,
  jobs~ : Int32 = 4,
) -> SaveRequest {
  {
    reference,
    output,
    format,
    platform,
    insecure,
    token,
    on_progress,
    on_tick,
    jobs,
  }
}

///|
pub impl Show for SaveRequest with fn to_string(self) {
  "SaveRequest(\{self.reference} -> \{self.output}, \{self.format})"
}

///|
pub extend SaveRequest with Show::{to_string, output}

///|
/// 一次 save 的产出摘要（CLI 用它打一行结果）。
pub(all) struct SaveResult {
  /// 真正落盘的位置：文件路径，或 OCI layout 的目录
  path : String
  format : ArchiveFormat
  /// 落盘字节总量
  bytes : Int32
  layers : Int32
  /// 选中的平台，`os/arch[/variant]`
  platform : String
} derive(Eq, Debug)

///|
pub extend SaveResult with Eq::{equal, not_equal}

///|
pub extend SaveResult with @debug.Debug::{to_repr}

///|
pub impl Show for SaveResult with fn to_string(self) {
  "\{self.format} -> \{self.path} (\{self.bytes} bytes, \{self.layers} layers, \{self.platform})"
}

///|
pub extend SaveResult with Show::{to_string, output}

///|
/// 从 registry 拉一个镜像并落盘。**全程不碰 docker / podman / dockerd。**
///
/// 这就是 issue #65 要的那条链路：
///
/// ```
/// registry ──[HTTP: token → manifest → blobs]──> 内存 ──[pack]──> tar / layout 目录
/// ```
pub async fn save_image(
  request : SaveRequest,
) -> SaveResult raise RegistryError {
  let reference = parse_reference(request.reference)
  let platform = match request.platform {
    Some(text) => parse_platform(text)
    None => host_platform()
  }
  let options = PullOptions::new(
    platform=Some(platform),
    insecure=request.insecure,
    token=request.token,
    on_progress=request.on_progress,
    on_tick=request.on_tick,
    concurrency=request.jobs,
  )

  let image = pull_image(reference, options~)
  // 打包这一步在大镜像上并不便宜（docker-archive 要把每层解压再套 tar），
  // 进度条停在 100% 之后先说明一句，免得「网络好了又卡住」
  notify_option(
    request.on_progress,
    Packing(note="packing the archive (decompress + tar)"),
  )
  let written = write_image(image, request.output, format=request.format)
  notify_option(
    request.on_progress,
    Writing(path=request.output, bytes=written.bytes),
  )
  {
    path: written.path,
    format: request.format,
    bytes: written.bytes.to_int(),
    layers: image.layers.length(),
    platform: describe_platform(platform),
  }
}

///|
fn notify_option(callback : ((PullEvent) -> Unit)?, event : PullEvent) -> Unit {
  match callback {
    Some(callback) => callback(event)
    None => ()
  }
}

///|
/// `linux/amd64` -> `Platform`；缺省 os 为 `linux`，只写一个词时当架构。
///
/// 不做模糊匹配（`x86_64` 不会自动变 `amd64`）：猜错平台的表现是
/// 「拉下来的是别的架构的镜像」，比报错难查得多。
pub fn parse_platform(text : String) -> @oci_spec.Platform raise RegistryError {
  let trimmed : String = text.trim().to_owned()
  if trimmed.is_empty() {
    raise InvalidReference("--platform is empty")
  }
  let parts : Array[String] = []
  for part in trimmed.split("/") {
    parts.push(part.to_owned())
  }
  if parts.length() > 3 {
    raise InvalidReference(
      "--platform \"\{trimmed}\" has too many parts (expect os/arch[/variant])",
    )
  }
  let (os, architecture, variant) = if parts.length() == 1 {
    ("linux", parts[0], None)
  } else if parts.length() == 2 {
    (parts[0], parts[1], None)
  } else {
    (parts[0], parts[1], Some(parts[2]))
  }
  if architecture.is_empty() {
    raise InvalidReference(
      "--platform \"\{trimmed}\" has an empty architecture",
    )
  }
  { architecture, os, os_version: None, os_features: None, variant, }
}

///|
fn describe_platform(platform : @oci_spec.Platform) -> String {
  match platform.variant {
    Some(variant) => "\{platform.os}/\{platform.architecture}/\{variant}"
    None => "\{platform.os}/\{platform.architecture}"
  }
}

///|
/// 落盘结果：写到哪、写了多少字节。
pub(all) struct WrittenArchive {
  path : String
  bytes : Int64
} derive(Eq, Debug)

///|
pub extend WrittenArchive with Eq::{equal, not_equal}

///|
pub extend WrittenArchive with @debug.Debug::{to_repr}

///|
/// 打开输出文件（截断写）。
async fn open_output(path : String) -> @fs.File raise RegistryError {
  @fs.create(path) catch {
    err => raise Io("\{path}: \{err}")
  }
}
