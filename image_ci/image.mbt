///|
/// 从本地镜像产物读出来的一层：`data` 是原始（可能压缩的）字节，
/// `media_type` 用来推断压缩方式，`diff_id` 只是从 config 里带出来备查。
pub(all) struct LayerSource {
  media_type : String
  data : Bytes
  diff_id : String
} derive(Debug)

///|
pub extend LayerSource with @debug.Debug::{to_repr}

///|
pub impl Show for LayerSource with fn to_string(self) {
  "\{self.media_type} (\{self.data.length()} bytes)"
}

///|
pub extend LayerSource with Show::{to_string, output}

///|
/// 一家镜像的来源：层 + 可读描述。
pub(all) struct ImageSource {
  /// 给报告和注解看的名字（文件路径 / `<stdin>` / 目录）
  name : String
  /// 输入格式：`docker-archive` / `oci-layout` / `docker-save`（单层 tar）
  format : String
  layers : Array[LayerSource]
} derive(Debug)

///|
pub extend ImageSource with @debug.Debug::{to_repr}

///|
pub impl Show for ImageSource with fn to_string(self) {
  "\{self.name} (\{self.format}, \{self.layers.length()} layers)"
}

///|
pub extend ImageSource with Show::{to_string, output}

///|
/// 镜像读不出来时抛的错。它属于「工具入参不对」，CLI 里与规则非法同为 exit 2。
pub(all) suberror ImageError {
  /// tar / JSON 结构不对
  Malformed(String)
  /// 输入格式不认识（比如给了个镜像名 `nginx:latest`）
  Unsupported(String)
  /// 磁盘读失败
  Io(String)
  /// 解压失败
  Decompress(String)
} derive(Eq, Debug)

///|
pub extend ImageError with Eq::{equal, not_equal}

///|
pub extend ImageError with @debug.Debug::{to_repr}

///|
pub impl Show for ImageError with fn to_string(self) {
  match self {
    Malformed(reason) => "malformed image input: \{reason}"
    Unsupported(reason) => "unsupported image input: \{reason}"
    Io(reason) => "cannot read image: \{reason}"
    Decompress(reason) => "cannot decompress layer: \{reason}"
  }
}

///|
pub extend ImageError with Show::{to_string, output}

///|
/// 从磁盘读一个本地镜像产物。
///
/// - 目录：按 OCI Image Layout 读（`index.json` + `oci-layout`）
/// - 文件：按 tar 读，先当 `docker save` 产物（`manifest.json`），
///   退而认单层 image tar（直接是文件系统 tar）
/// - `-`：从 stdin 读 tar
pub fn ImageSource::load(path : String) -> ImageSource raise ImageError {
  if path == "-" {
    let data = match read_stdin() {
      Ok(data) => data
      Err(reason) => raise Io(reason)
    }
    read_archive(data, "<stdin>")
  } else if is_directory(path) {
    read_oci_layout(path, read_utf8(path + "/index.json", "index"))
  } else {
    let data = match read_bytes(path) {
      Ok(data) => data
      Err(reason) => raise Io(reason)
    }
    read_archive(data, path)
  }
}

///|
/// 从内存里的 tar 读镜像：docker save 产物，或单层 tar。
pub fn ImageSource::from_tar_bytes(
  data : Bytes,
  name~ : String = "<memory>",
) -> ImageSource raise ImageError {
  read_archive(data, name)
}

///|
/// 从已读入的 contents 构建 OCI layout 来源，供测试与内存场景使用。
pub fn ImageSource::from_oci_layout(
  name : String,
  index_json : String,
  config_json : String,
  layer_blobs : Array[Bytes],
) -> ImageSource raise ImageError {
  let config = @oci_spec.parse_image_config_lenient(config_json) catch {
    err => raise Malformed("config.json: \{err.to_string()}")
  }
  let diff_ids = config.rootfs.diff_ids
  let layers = []
  for index, data in layer_blobs {
    let diff_id = if index < diff_ids.length() { diff_ids[index] } else { "" }
    layers.push({
      // 内存输入默认按未压缩处理：调用方给的是解压后的 blob 还是 gzip 由它自己知道，
      // 这里统一用 none，需要的走 `from_oci_layout_gzip`
      media_type: @oci_spec.oci_layer_media_type,
      data,
      diff_id,
    })
  }
  let _ = index_json
  { name, format: "oci-layout", layers, }
}

///|
/// 读一个 tar 输入：先找 `manifest.json`（docker save），否则按单层 tar 处理。
fn read_archive(data : Bytes, name : String) -> ImageSource raise ImageError {
  let entries = @layer_tree.parse_tar_entries(data) catch {
    err => raise Malformed("\{name}: \{err.to_string()}")
  }
  let has_manifest = entries.any(fn(entry) {
    strip_dot_slash(entry.path) == "manifest.json"
  })
  if has_manifest {
    read_docker_archive(data, name)
  } else {
    // 单层 tar：整份就是一个文件系统层
    {
      name,
      format: "tar",
      layers: [
        { media_type: @oci_spec.oci_layer_media_type, data, diff_id: "", },
      ],
    }
  }
}

///|
/// `docker save` 产物：`manifest.json` 里记 `Config` 与 `Layers`（层 tar 的路径）。
fn read_docker_archive(
  data : Bytes,
  name : String,
) -> ImageSource raise ImageError {
  let manifest = @layer_tree.read_file_from_tar(data, "manifest.json") catch {
    err => raise Malformed("\{name}: \{err.to_string()}")
  }
  let manifest = match manifest {
    Some(data) => data
    None => raise Malformed("\{name}: manifest.json not found in tar")
  }
  let text = utf8_text(manifest)
  let json = @json.parse(text) catch {
    err => raise Malformed("\{name}: manifest.json: \{err.to_string()}")
  }
  let record = first_manifest_record(json, name)
  let config_text = match record.1 {
    Some(config_path) => {
      let raw = @layer_tree.read_file_from_tar(data, config_path) catch {
        err =>
          raise Malformed("\{name}: config \{config_path}: \{err.to_string()}")
      }
      Some(
        utf8_text(
          match raw {
            Some(data) => data
            None =>
              raise Malformed("\{name}: config \{config_path} not found in tar")
          },
        ),
      )
    }
    None => None
  }
  let config = match config_text {
    Some(text) =>
      Some(
        @oci_spec.parse_image_config_lenient(text) catch {
          err => raise Malformed("\{name}: config: \{err.to_string()}")
        },
      )
    None => None
  }
  let diff_ids = match config {
    Some(config) => config.rootfs.diff_ids
    None => []
  }
  let layers = []
  for index, layer_path in record.0 {
    let lookup = strip_dot_slash(layer_path)
    let raw = @layer_tree.read_file_from_tar(data, lookup) catch {
      err => raise Malformed("\{name}: layer \{layer_path}: \{err.to_string()}")
    }
    let raw = match raw {
      Some(raw) => raw
      None => raise Malformed("\{name}: layer \{layer_path} not found in tar")
    }
    layers.push({
      media_type: docker_media_type(raw.to_owned()),
      data: raw.to_owned(),
      diff_id: if index < diff_ids.length() {
        diff_ids[index]
      } else {
        ""
      },
    })
  }
  { name, format: "docker-archive", layers, }
}

///|
/// 取 `manifest.json` 的第一条记录：`(Layers, Config?)`。
fn first_manifest_record(
  json : Json,
  name : String,
) -> (Array[String], String?) raise ImageError {
  let items = match json {
    Json::Array(items) => items
    _ => raise Malformed("\{name}: manifest.json must be an array")
  }
  if items.is_empty() {
    raise Malformed("\{name}: manifest.json is empty")
  }
  let fields = match items[0] {
    Json::Object(fields) => fields
    _ => raise Malformed("\{name}: manifest.json[0] must be an object")
  }
  let layer_values = match fields.get("Layers") {
    Some(Json::Array(layers)) => layers
    _ => raise Malformed("\{name}: manifest.json[0].Layers must be an array")
  }
  let layers = layer_values.map(fn(item) {
    match item {
      Json::String(path) => path
      _ => ""
    }
  })
  if layers.any(fn(path) { path.is_empty() }) {
    raise Malformed("\{name}: manifest.json[0].Layers must contain strings")
  }
  let config = match fields.get("Config") {
    Some(Json::String(path)) => Some(path)
    Some(_) =>
      raise Malformed("\{name}: manifest.json[0].Config must be a string")
    None => None
  }
  (layers, config)
}

///|
/// OCI Image Layout 目录：`index.json` 指向 manifest，manifest 指向 config 与 layer blob。
///
/// 这里只读本地目录里的相对路径，不做 digest 校验（校验在 P1 的 `oci_spec` 里单测，
/// 门禁阶段多一次哈希没有收益）。
fn read_oci_layout(
  directory : String,
  index_text : String,
) -> ImageSource raise ImageError {
  let json = @json.parse(index_text) catch {
    err => raise Malformed("\{directory}/index.json: \{err.to_string()}")
  }
  let manifest_digest = first_manifest_digest(json, directory)
  let manifest_path = blob_path(directory, manifest_digest)
  let manifest_text = read_utf8(manifest_path, "manifest")
  let document = try @oci_spec.parse_document(manifest_text) catch {
    err => raise Malformed("\{manifest_path}: \{err.to_string()}")
  } noraise {
    document => document
  }
  let manifest = match document {
    @oci_spec.OciDocument::Manifest(manifest) => manifest
    other =>
      raise Malformed(
        "\{manifest_path}: expected a manifest, got \{other.to_string()}",
      )
  }
  let config_digest = manifest.config.digest
  let config_text = read_utf8(blob_path(directory, config_digest), "config")
  let config = @oci_spec.parse_image_config_lenient(config_text) catch {
    err => raise Malformed("\{config_digest}: \{err.to_string()}")
  }
  let diff_ids = config.rootfs.diff_ids
  let layers = []
  for index, descriptor in manifest.layers {
    let path = blob_path(directory, descriptor.digest)
    let data = match read_bytes(path) {
      Ok(data) => data
      Err(reason) => raise Io("cannot read \{path}: \{reason}")
    }
    layers.push({
      media_type: descriptor.media_type,
      data,
      diff_id: if index < diff_ids.length() {
        diff_ids[index]
      } else {
        ""
      },
    })
  }
  { name: directory, format: "oci-layout", layers, }
}

///|
/// `index.json` 里第一个 manifest descriptor 的 digest。
fn first_manifest_digest(
  json : Json,
  directory : String,
) -> String raise ImageError {
  let index = match index_from_json(json) {
    Ok(index) => index
    Err(err) => raise Malformed("\{directory}/index.json: \{err.to_string()}")
  }
  if index.manifests.is_empty() {
    raise Malformed("\{directory}/index.json contains no manifest")
  }
  index.manifests[0].digest
}

///|
/// blob 在 layout 目录里的路径：`<dir>/blobs/<算法>/<hex>`。
fn blob_path(directory : String, digest : String) -> String {
  match digest.find(":") {
    Some(separator) => {
      let algorithm = digest[:separator].to_owned()
      let hex = digest[separator + 1:].to_owned()
      "\{directory}/blobs/\{algorithm}/\{hex}"
    }
    None => "\{directory}/blobs/\{digest}"
  }
}

///|
/// 读一个 utf-8 文件，失败时带上用途。
fn read_utf8(path : String, what : String) -> String raise ImageError {
  let data = match read_bytes(path) {
    Ok(data) => data
    Err(reason) => raise Io("cannot read \{what} \{path}: \{reason}")
  }
  utf8_text(data)
}

///|
/// 解压一层，得到可以直接喂给 P3 的字节。
///
/// docker save 的层 tar 通常没压缩（`layer.tar`），OCI layout 的 blob 多带 `+gzip`，
/// 两种都由 media type 推断；media type 认不出来时按魔数兜底。
///
/// 兜底这件事现在要覆盖 zstd：`docker save` 会把 zstd 层压成 gzip 再写出，
/// 但 `docker save --format oci`（以及各种 OCI layout 产物）里的 blob
/// 就是原始的 `tar+zstd`，而 `manifest.json` 那条老路径不带 media type。
/// 认不出来就会把压缩字节当 tar 解析，报一个「tar 被截断」——看着像坏镜像，
/// 其实是没解压。
pub fn LayerSource::raw_bytes(self : LayerSource) -> Bytes raise ImageError {
  let algorithm = @layer_tree.compression_of(self.media_type)
  let effective = if algorithm != "none" {
    algorithm
  } else if looks_gzipped(self.data) {
    "gzip"
  } else if looks_zstd(self.data) {
    "zstd"
  } else {
    "none"
  }
  @layer_tree.decompress_layer(self.data, effective) catch {
    err => raise Decompress(err.to_string())
  }
}

///|
/// gzip 魔数：`1f 8b`。
fn looks_gzipped(data : Bytes) -> Bool {
  data.length() >= 2 && data[0] == b'\x1f' && data[1] == b'\x8b'
}

///|
/// zstd 帧魔数：`28 b5 2f fd`（小端读是 `0xFD2FB528`）。
fn looks_zstd(data : Bytes) -> Bool {
  data.length() >= 4 &&
  data[0] == b'\x28' &&
  data[1] == b'\xb5' &&
  data[2] == b'\x2f' &&
  data[3] == b'\xfd'
}

///|
/// docker save 里的层没有 media type，靠魔数判断。
fn docker_media_type(data : Bytes) -> String {
  if looks_gzipped(data) {
    @oci_spec.docker_layer_gzip_media_type
  } else if looks_zstd(data) {
    @oci_spec.oci_layer_zstd_media_type
  } else {
    @oci_spec.docker_layer_media_type
  }
}

///|
/// `manifest.json` 里的路径可能带 `./` 前缀，tar 查找要能对上。
fn strip_dot_slash(path : String) -> String {
  if path.has_prefix("./") {
    path[2:].to_owned()
  } else {
    path
  }
}

///|

///|
/// 解析 index.json，错误转成人话。
fn index_from_json(json : Json) -> Result[@oci_spec.Index, String] {
  let document = try @oci_spec.parse_document_json(json) catch {
    err => return Err(err.to_string())
  } noraise {
    document => document
  }
  match document {
    @oci_spec.OciDocument::IndexDoc(index) => Ok(index)
    other => Err("expected an image index, got \{other.to_string()}")
  }
}

///|
/// 读一个文件，把 IO 错误转成人话（`fs` 的错误类型不实现 `Show`，这里自己拆）。
fn read_bytes(path : String) -> Result[Bytes, String] noraise {
  let data = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(message) => return Err(message)
  }
  Ok(data)
}

///|
/// 从 stdin 读全部字节。
fn read_stdin() -> Result[Bytes, String] {
  read_bytes("/dev/stdin")
}

///|
/// 路径是否是目录；不存在或没权限都当「不是目录」。
fn is_directory(path : String) -> Bool noraise {
  @fs.is_dir(path) catch {
    @fs.IOError(_) => false
  }
}

///|
/// 把字节当 utf-8 解码。
fn utf8_text(data : BytesView) -> String {
  @encoding.decoder(UTF8).decode_lossy(data)
}
