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
  /// 边下边写盘（层先进临时文件），见 `PullOptions::stream_to_disk`
  stream_to_disk : Bool
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
  stream_to_disk~ : Bool = true,
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
    stream_to_disk,
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
    stream_to_disk=request.stream_to_disk,
  )

  // 拉取中途失败：`pull_image` 自己会收掉临时目录，这里只管「拉到了之后」
  let image = pull_image(reference, options~)
  // 打包这一步在大镜像上并不便宜（docker-archive 要把每层解压再套 tar），
  // 进度条停在 100% 之后先说明一句，免得「网络好了又卡住」
  notify_option(
    request.on_progress,
    Packing(note="packing the archive (decompress + tar)"),
  )
  // 打包失败也要收掉流式落盘的临时目录：它跟这次 save 一起生、一起死
  errdefer discard_image(image)
  // docker-archive 要的是**未压缩**字节，而「读进内存」那条拉取路径会把压缩后的
  // 层整份留在内存里。打包前先把它们落到磁盘：否则一个 700MB 的镜像要同时占
  // 「全部压缩层 + 全部解压层」，小内存机器上直接被 OOM 杀掉（issue #122）
  if request.format is DockerArchive {
    // `spill_layers_to_disk` 的错本来就带着路径，原样往上抛即可
    spill_layers_to_disk(image)
  }
  let written = write_image(image, request.output, format=request.format)
  discard_image(image)
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

///|
/// 一次「只拉不打包」的请求（`dive <ref>` 在主链路里用）。
///
/// 与 `SaveRequest` 的区别只有一项：**没有 `output`**。拉下来的字节留在
/// `@fs.tmpdir` 下的临时目录里，由调用方读完再 `discard_streamed`。
/// 层是压缩 blob 原样落地，不解压、不重新套 tar——`docker-archive` 那一步
/// 在「我要分析它」这件事上纯属多余（见 `docs/registry-to-tar-survey.md`：
/// 那层壳是给 `docker load` 用的，分析链路从来不需要 `layer.tar` 这个名字）。
pub(all) struct StreamRequest {
  reference : String
  platform : String?
  insecure : Bool
  token : String?
  on_progress : ((PullEvent) -> Unit)?
  on_tick : (() -> Unit noraise)?
  jobs : Int32
}

///|
pub fn StreamRequest::new(
  reference~ : String,
  platform~ : String? = None,
  insecure~ : Bool = false,
  token~ : String? = None,
  on_progress~ : ((PullEvent) -> Unit)? = None,
  on_tick~ : (() -> Unit noraise)? = None,
  jobs~ : Int32 = 4,
) -> StreamRequest {
  { reference, platform, insecure, token, on_progress, on_tick, jobs, }
}

///|
/// 拉下来的一个 blob 落在磁盘上的样子。
pub(all) struct StreamedBlob {
  media_type : String
  digest : String
  /// 压缩 blob 的临时文件
  path : String
  /// 压缩后的大小
  size : Int64
} derive(Eq, Debug)

///|
pub extend StreamedBlob with Eq::{equal, not_equal}

///|
pub extend StreamedBlob with @debug.Debug::{to_repr}

///|
/// 一次「只拉不打包」的产物：config 的字节已经读好，层还躺在临时目录里。
///
/// config 只有几十 KB，直接带着走；层一律按路径给——把 700MB 读成 `Bytes`
/// 就是为了省掉一次 `fopen`，账不划算。
pub(all) struct StreamedImage {
  reference : String
  config_json : String
  layers : Array[StreamedBlob]
  /// 临时目录；`discard_streamed` 收它
  staging : String
} derive(Eq, Debug)

///|
pub extend StreamedImage with Eq::{equal, not_equal}

///|
pub extend StreamedImage with @debug.Debug::{to_repr}

///|
/// 从 registry 拉一个镜像，**不做任何打包**：blob 原样落在临时目录里。
///
/// 这是不 save 时的正规路径。以前分析一个 registry 里的镜像要先压一张
/// docker-archive：每层解压一遍再套进 tar（2 GiB 的归档、几十秒到十几分钟），
/// 然后分析链路又把 tar 拆开、把层**再解压**一遍。那些解压出来的字节
/// 分析要用、tar 只是路过。
pub async fn stream_image(
  request : StreamRequest,
) -> StreamedImage raise RegistryError {
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
    stream_to_disk=true,
  )
  let image = pull_image(reference, options~)
  // 这之后无论成败，临时目录都不归 `RemoteImage` 管了：成功时归调用方
  // （`discard_streamed`），失败时在这里收掉——留着只会攒垃圾
  let mut handed_off = false
  errdefer (if !handed_off { discard_image(image) })
  // 走到这儿层可能还在内存里（`stream_to_disk` 保证不是，但保险起见统一落到
  // 磁盘：这条路径的契约就是「层只有路径」）
  spill_layers_to_disk(image) catch {
    err => raise Io("spilling layers to disk: \{err}")
  }
  let staging = match image.staging {
    Some(directory) => directory
    // `spill_layers_to_disk` 之后一定有目录：没有就是这个契约被破坏
    None => raise Io("pulled image has no staging directory after spilling")
  }
  let config_json = @encoding.decoder(UTF8).decode_lossy(
    blob_bytes(image.config),
  )
  let layers : Array[StreamedBlob] = []
  for index, layer in image.layers {
    let path = match layer.path {
      Some(path) => path
      None => {
        // 层没落在文件上：把字节写出去，之后统一按路径处理
        let target = "\{staging}/layer-\{index}.blob"
        @fs.write_file(target, layer.bytes()) catch {
          err => raise Io("\{target}: \{err}")
        }
        target
      }
    }
    layers.push({
      media_type: layer.media_type,
      digest: layer.digest,
      path,
      size: layer.compressed_size(),
    })
  }
  handed_off = true
  {
    reference: reference.original,
    config_json,
    layers,
    // 临时目录的归属交给调用方：`discard_streamed` 收它。
    // 这里不再调 `discard_image`——那会把刚拿到的 blob 一起删掉
    staging,
  }
}

///|
/// 收掉一次流式拉取的临时目录。调用方必须在**读完之后**调。
pub async fn discard_streamed(image : StreamedImage) -> Unit noraise {
  discard_directory(image.staging)
}
