///|
/// 从本地镜像产物读出来的一层：`data` 是原始（可能压缩的）字节，
/// `media_type` 用来推断压缩方式，`diff_id` 只是从 config 里带出来备查。
pub(all) struct LayerSource {
  media_type : String
  /// 层在输入文件里的起点。文件输入时 `data` 为空，字节按需从 `offset` 读
  /// ——一张 2 GiB 的 tar 不该先整个搬进内存
  offset : Int64
  /// 层占多少字节。内存输入时等于 `data.length()`，可据此判断是哪种来源
  size : Int64
  /// 独立文件形式的层（OCI layout 的 blob）；`None` 表示字节在同名 tar 的
  /// `offset` 处（或者就在 `data` 里）
  source_path : String?
  /// 内存里的那份字节；空表示字节在磁盘上，需要时按 `offset` 读
  data : Bytes
  diff_id : String
} derive(Debug)

///|
pub extend LayerSource with @debug.Debug::{to_repr}

///|
pub impl Show for LayerSource with fn to_string(self) {
  "\{self.media_type} (\{self.data.length()} bytes in memory)"
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
///
/// 文件输入**不整份读入**：tar 的随机访问只需要「读 512 字节头」与
/// 「按头里记的偏移读数据」，所以层只记一个 `offset`，
/// 真正的字节在 `LayerSource::raw_bytes` 里按需取。
/// 一张 2 GiB 的 tar 因此不再要求一块 2 GiB 的连续内存（issue #113）。
pub fn ImageSource::load(path : String) -> ImageSource raise ImageError {
  if path == "-" {
    let data = match read_stdin() {
      Ok(data) => data
      Err(reason) => raise Io(reason)
    }
    read_archive(SliceInput::of_bytes(data), "<stdin>")
  } else if is_directory(path) {
    read_oci_layout(path, read_utf8(path + "/index.json", "index"))
  } else {
    let file = open_image_file(path)
    errdefer file.close()
    let source = read_archive(SliceInput::of_file(file), path)
    file.close()
    source
  }
}

///|
/// 从内存里的 tar 读镜像：docker save 产物，或单层 tar。
pub fn ImageSource::from_tar_bytes(
  data : Bytes,
  name~ : String = "<memory>",
) -> ImageSource raise ImageError {
  read_archive(SliceInput::of_bytes(data), name)
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
      offset: 0L,
      size: data.length().to_int64(),
      source_path: None,
      data,
      diff_id,
    })
  }
  let _ = index_json
  { name, format: "oci-layout", layers, }
}

///|
/// 「一段可随机访问的字节」：文件从磁盘按需读，内存直接切。
///
/// 解析器（`@layer_tree.MappedReader`）只要两个原语：总长与 `read_at`，
/// 所以这里不必把两种来源的差异漏到上层。
priv enum SliceInput {
  OnFile(ImageFile)
  InMemory(Bytes)
}

///|
fn SliceInput::of_file(file : ImageFile) -> SliceInput {
  OnFile(file)
}

///|
fn SliceInput::of_bytes(data : Bytes) -> SliceInput {
  InMemory(data)
}

///|
fn SliceInput::length(self : SliceInput) -> Int64 {
  match self {
    OnFile(file) => file.size
    InMemory(data) => data.length().to_int64()
  }
}

///|
/// 读一段：`OnFile` 越界读会被截短（调用方靠长度判断「流断了」），
/// `InMemory` 越界直接报错。
fn SliceInput::read_at(
  self : SliceInput,
  position : Int64,
  length : Int32,
) -> Bytes raise ImageError {
  match self {
    OnFile(file) => file.read_at(position, length)
    InMemory(data) => {
      // 文件那头会把越界的请求读短；内存这头照做，两条路径的语义才一致
      let start = position.to_int()
      let end = start + length
      let real_end = if end > data.length() { data.length() } else { end }
      if start >= real_end {
        Bytes::make(0, b'\x00')
      } else {
        data[start:real_end].to_owned()
      }
    }
  }
}

///|
/// 读一个 tar 输入：先找 `manifest.json`（docker save），否则按单层 tar 处理。
fn read_archive(
  input : SliceInput,
  name : String,
) -> ImageSource raise ImageError {
  let reader = @layer_tree.MappedReader::new(
    length=input.length(),
    // 读失败就当「到这儿为止」（空字节）：`MappedReader` 会把它报成截断。
    // 反过来把请求截短是不行的——那等于告诉它「文件到这儿结束了」，
    // 一份完好的输入会被当成空包
    read_at=fn(position, length) noraise {
      input.read_at(position, length) catch {
        _ => Bytes::make(0, b'\x00')
      }
    },
  )
  let entries = @layer_tree.parse_tar_entries_from(reader) catch {
    err => raise Malformed("\{name}: \{err.to_string()}")
  }
  let has_manifest = entries.any(fn(entry) {
    strip_dot_slash(entry.path) == "manifest.json"
  })
  if has_manifest {
    read_docker_archive(input, reader, name)
  } else {
    // 单层 tar：整份就是一个文件系统层
    match input {
      InMemory(data) =>
        {
          name,
          format: "tar",
          layers: [
            {
              media_type: @oci_spec.oci_layer_media_type,
              offset: 0L,
              size: data.length().to_int64(),
              source_path: None,
              data,
              diff_id: "",
            },
          ],
        }
      OnFile(_) =>
        {
          name,
          format: "tar",
          layers: [
            {
              media_type: @oci_spec.oci_layer_media_type,
              offset: 0L,
              size: input.length(),
              source_path: Some(name),
              data: Bytes::make(0, b'\x00'),
              diff_id: "",
            },
          ],
        }
    }
  }
}

///|
/// `docker save` 产物：`manifest.json` 里记 `Config` 与 `Layers`（层 tar 的路径）。
fn read_docker_archive(
  input : SliceInput,
  reader : @layer_tree.MappedReader,
  name : String,
) -> ImageSource raise ImageError {
  let manifest = @layer_tree.read_mapped_file(reader, "manifest.json") catch {
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
      let raw = @layer_tree.read_mapped_file(reader, config_path) catch {
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
    let entry = @layer_tree.find_tar_entry(reader, lookup) catch {
      err => raise Malformed("\{name}: layer \{layer_path}: \{err.to_string()}")
    }
    let entry = match entry {
      Some(entry) => entry
      None => raise Malformed("\{name}: layer \{layer_path} not found in tar")
    }
    // 层的边界按**声明**的长度算：「文件被砍在层的数据段中间」在这里就能
    // 发现，而不是等解压时拿到一段「短而不说」的字节
    if entry.data_offset_64 + entry.size.to_int64() > input.length() {
      raise Malformed(
        "\{name}: layer \{layer_path} declares \{entry.size} bytes at offset \{entry.data_offset_64}, but the archive ends at \{input.length()}",
      )
    }
    // 层只记位置：字节要么在输入文件里（按需读），要么在内存输入的那块里。
    // 内存那块是**整份输入**，所以 `offset` 一样是 `entry` 的绝对偏移——
    // 不能写 0，那是「整份输入就是这一层」的意思
    let (offset, data) = match input {
      OnFile(_) => (entry.data_offset_64, Bytes::make(0, b'\x00'))
      InMemory(whole) => {
        // 内存这块就是整份输入：数据段被截断在装载时就能发现，
        // 不必等到有人把层读出来、拿到一段「短但不说」的字节
        if entry.data_offset_64 + entry.size.to_int64() >
          whole.length().to_int64() {
          raise Malformed(
            "\{name}: layer \{layer_path} declares \{entry.size} bytes but the archive ends early",
          )
        }
        (entry.data_offset_64, whole)
      }
    }
    layers.push({
      media_type: match docker_media_type(input, entry) {
        Some(media_type) => media_type
        None => @oci_spec.docker_layer_media_type
      },
      offset,
      size: entry.size.to_int64(),
      source_path: match input {
        OnFile(_) => Some(name)
        InMemory(_) => None
      },
      data,
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
  // blob 也只记位置：`blobs/sha256/<hex>` 在磁盘上本来就是按偏移能读的文件，
  // 一张 layout 里几百 MB 的层没有理由先整个读进来
  let diff_ids = config.rootfs.diff_ids
  let layers = []
  for index, descriptor in manifest.layers {
    let path = blob_path(directory, descriptor.digest)
    let size = match file_size(path) {
      Ok(size) => size
      Err(reason) => raise Io(reason)
    }
    layers.push({
      media_type: descriptor.media_type,
      offset: 0L,
      size,
      source_path: Some(path),
      data: Bytes::make(0, b'\x00'),
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
/// 一份「可随机访问的输入」：文件从磁盘按需读，内存直接切。
///
/// 存在的理由很具体：`docker save` 出来的 tar 可以到 2 GiB 以上，一次性
/// `read_file_to_bytes` 既吃内存，也会在长度越过 Int32 边界时以一句
/// `Bad address` 收场（issue #113）。tar 的随机访问只需要「读 512 字节头」
/// 和「按头里记的偏移读数据」两件事，所以按需读就够。
///
/// 底层用 `moonbitlang/x/fs`：它是同步的 `fopen`/`fseek`/`fread`，
/// 于是整个装载路径不必变成 `async`（分析链路和 web playground 都还在调它）。
pub struct ImageFile {
  path : String
  size : Int64
  /// 文件输入时为 `None`；内存输入时就是那块字节
  bytes : Bytes?
}

///|
/// 打开一份文件输入。
fn open_image_file(path : String) -> ImageFile raise ImageError {
  let size = match file_size(path) {
    Ok(size) => size
    Err(reason) => raise Io(reason)
  }
  { path, size, bytes: None, }
}

///|
/// 按偏移读：文件走 `fseek` + `fread`，内存从已读入的字节里切片。
///
/// 越界的请求读短（返回实际有的那些字节），调用方据此判断「流断了」。
fn ImageFile::read_at(
  self : ImageFile,
  position : Int64,
  length : Int32,
) -> Bytes raise ImageError {
  if length <= 0 || position < 0L || position >= self.size {
    return Bytes::make(0, b'\x00')
  }
  let want = if position + length.to_int64() > self.size {
    (self.size - position).to_int()
  } else {
    length
  }
  match self.bytes {
    Some(data) => {
      let start = position.to_int()
      let end = start + want
      if end > data.length() {
        return Bytes::make(0, b'\x00')
      }
      data[start:end].to_owned()
    }
    None =>
      match read_file_chunk(self.path, position, want) {
        Ok(data) => data
        Err(reason) => raise Io(reason)
      }
  }
}

///|
/// 收掉句柄：这条路每次读都现开现关，账户里没有常驻句柄，收尾是空操作。
///
/// 留这个函数是因为「文件输入有句柄」这件事本身要有个落脚点：以后换成
/// 常驻句柄，只用改这里，装载路径不必动。
fn ImageFile::close(self : ImageFile) -> Unit {
  ignore(self.path)
}

///|
/// 文件大小。
fn file_size(path : String) -> Result[Int64, String] noraise {
  file_length(path)
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
pub async fn LayerSource::raw_bytes(
  self : LayerSource,
) -> Bytes raise ImageError {
  let algorithm = @layer_tree.compression_of(self.media_type)
  let compressed = self.encoded_bytes()
  let effective = if algorithm != "none" {
    algorithm
  } else if looks_gzipped(compressed) {
    "gzip"
  } else if looks_zstd(compressed) {
    "zstd"
  } else {
    "none"
  }
  @layer_tree.decompress_layer(compressed, effective) catch {
    err => raise Decompress(err.to_string())
  }
}

///|
/// 层在输入里的原始字节（可能还是压缩的）：内存里那份，或者从
/// `source_path` / `offset` 上按块读回来。
///
/// 这条路径仍要「一整块字节」——解压入口只收 `BytesView`。但它只发生在
/// 调用方明确要整份层的时候；解析镜像结构本身已经不必碰它了。
pub fn LayerSource::encoded_bytes(self : LayerSource) -> Bytes raise ImageError {
  match self.source_path {
    Some(path) =>
      // 层可能是几百 MB：一次按长度读回来，交给解压器
      match read_layer_bytes(path, self.offset, self.size) {
        Ok(data) => data
        Err(reason) => raise Io(reason)
      }
    None =>
      if self.size == 0 {
        self.data
      } else {
        // 内存输入的同名 tar：字节就在那块 `data` 的 `offset` 处
        let start : Int32 = self.offset.to_int()
        let end = start + self.size.to_int()
        if start < 0 || end > self.data.length() {
          raise Malformed(
            "layer at offset \{self.offset} declares \{self.size} bytes but the input ends early",
          )
        }
        self.data[start:end].to_owned()
      }
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
/// docker save 里的层没有 media type，靠前几个字节的魔数判断。
///
/// 只读一个 512 字节的窗口就够——层可能有几百 MB，判压缩方式不该碰它。
fn docker_media_type(
  input : SliceInput,
  entry : @layer_tree.TarEntry,
) -> String? noraise {
  let head = input.read_at(entry.data_offset_64, 8) catch { _ => return None }
  if looks_gzipped(head) {
    Some(@oci_spec.docker_layer_gzip_media_type)
  } else if looks_zstd(head) {
    Some(@oci_spec.oci_layer_zstd_media_type)
  } else {
    None
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

///|
/// 把一层的字节整段读回来（超过 16 MiB 就分几次拼）。
///
/// 解压入口只收 `BytesView`，所以这一步仍要一整块；但它只发生在「真的要
/// 解压这一层」的时候。分次拼是为了不让单次 `fread` 去碰 2 GiB 的长度——
/// 那正是 issue #113 里 `Bad address` 的来路。
fn read_layer_bytes(
  path : String,
  position : Int64,
  size : Int64,
) -> Result[Bytes, String] noraise {
  if size <= 0L {
    return Ok(Bytes::make(0, b'\x00'))
  }
  if size > 2147483647L {
    return Err(
      "\{path}: the layer is \{size} bytes, which cannot be held in one piece (over 2 GiB)",
    )
  }
  let chunk : Int32 = 16 * 1024 * 1024
  let total = size.to_int()
  if total <= chunk {
    return read_file_chunk(path, position, total)
  }
  let buffer = @buffer.Buffer(size_hint=total)
  let mut offset = 0
  while offset < total {
    let want = if total - offset < chunk { total - offset } else { chunk }
    let data = match read_file_chunk(path, position + offset.to_int64(), want) {
      Ok(data) => data
      Err(reason) => return Err(reason)
    }
    if data.length() == 0 {
      return Err(
        "\{path}: \{position + offset.to_int64()}: the layer ends early (\{offset} of \{total} bytes read)",
      )
    }
    buffer.write_bytes(data)
    offset = offset + data.length()
  }
  Ok(buffer.to_bytes())
}

///|
/// 进程当前占用的物理内存（kB），读不到时返回 0。
///
/// 给「装载大归档时峰值内存不随体积涨」这类用例读数：这是唯一一条
/// 「不靠肉眼」的证据。读不到不该让分析失败，所以不抛。
pub fn resident_kb() -> Int32 {
  match read_file_chunk("/proc/self/status", 0L, 65536) {
    Ok(data) => proc_vm_kb(utf8_text(data), "VmRSS:")
    Err(_) => 0
  }
}

///|
/// 从 `/proc/self/status` 的内容里取 `key`（`VmRSS:` / `VmHWM:`）的 kB 值。
fn proc_vm_kb(text : String, key : String) -> Int32 {
  for line in text.split("\n") {
    if line.has_prefix(key) {
      let mut value = 0
      let mut started = false
      for code in line.to_array() {
        if code >= '0' && code <= '9' {
          value = value * 10 + (code.to_int() - '0'.to_int())
          started = true
        } else if started {
          return value
        }
      }
      return value
    }
  }
  0
}
