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
  /// 打一行进度（写 stderr 由调用方决定）
  on_progress : ((String) -> Unit)?
}

///|
pub fn SaveRequest::new(
  reference~ : String,
  output~ : String,
  format~ : ArchiveFormat = DockerArchive,
  platform~ : String? = None,
  insecure~ : Bool = false,
  token~ : String? = None,
  on_progress~ : ((String) -> Unit)? = None,
) -> SaveRequest {
  { reference, output, format, platform, insecure, token, on_progress, }
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
  )
  notify_option(request.on_progress, "pulling \{reference.canonical()}")
  let image = pull_image(reference, options~)
  let bundle = package_image(image, format=request.format)
  let written = write_bundle(bundle, request.output)
  {
    path: written.path,
    format: request.format,
    bytes: written.bytes,
    layers: image.layers.length(),
    platform: describe_platform(platform),
  }
}

///|
fn notify_option(callback : ((String) -> Unit)?, message : String) -> Unit {
  match callback {
    Some(callback) => callback(message)
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
/// 落盘结果。
priv struct WrittenArchive {
  path : String
  bytes : Int32
}

///|
/// 把产物写出去：
///
/// - docker-archive：写**一个 tar 文件**，路径就是 `request.output`
/// - OCI layout：写**一个目录**，目录里按 `blobs/sha256/<hex>` 摆开
///
/// 目录已存在且非空就直接拒绝——半覆盖一个 layout 会留下
/// 「index.json 指着不存在的 blob」这种坏状态，修起来比重新拉一遍麻烦。
async fn write_bundle(
  bundle : ArchiveBundle,
  output : String,
) -> WrittenArchive raise RegistryError {
  match bundle.format {
    DockerArchive => {
      let tar = bundle.files[0].1
      @fs.write_file(output, tar) catch {
        err => raise Io("\{output}: \{err}")
      }
      { path: output, bytes: tar.length(), }
    }
    OciLayout => {
      let exists = @fs.exists(output) catch {
        err => raise Io("\{output}: \{err}")
      }
      if exists {
        let entries = @fs.readdir(output) catch {
          err => raise Io("\{output}: \{err}")
        }
        if !entries.is_empty() {
          raise Io(
            "\{output} already exists and is not empty; pass a fresh directory for --format oci",
          )
        }
      } else {
        @fs.mkdir(output, recursive=true) catch {
          err => raise Io("\{output}: \{err}")
        }
      }
      @fs.mkdir("\{output}/blobs/sha256", recursive=true) catch {
        err => raise Io("\{output}/blobs/sha256: \{err}")
      }
      let mut bytes = 0
      for entry in bundle.files {
        let (name, data) = entry
        let destination = "\{output}/\{name}"
        @fs.write_file(destination, data) catch {
          err => raise Io("\{destination}: \{err}")
        }
        bytes = bytes + data.length()
      }
      { path: output, bytes, }
    }
  }
}
