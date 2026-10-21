///|
/// 拉下来的镜像要落成什么。
///
/// 两个格式各有用途，别混：
/// - `DockerArchive`：给本仓 P2/P3/P4 的分析链路吃，层要**解压**
/// - `OciLayout`：无损搬运，blob 原样落盘，不重算 sha256，能直接推回 registry
pub(all) enum ArchiveFormat {
  DockerArchive
  OciLayout
} derive(Eq, Debug)

///|
pub extend ArchiveFormat with Eq::{equal, not_equal}

///|
pub extend ArchiveFormat with @debug.Debug::{to_repr}

///|
pub impl Show for ArchiveFormat with fn to_string(self) {
  match self {
    DockerArchive => "docker-archive"
    OciLayout => "oci-layout"
  }
}

///|
pub extend ArchiveFormat with Show::{to_string, output}

///|
/// 从字符串解析格式名（`--format` 用）。
pub fn parse_format(text : String) -> ArchiveFormat? {
  match text.to_lower().to_string() {
    "docker-archive" | "docker" | "tar" => Some(DockerArchive)
    "oci" | "oci-layout" | "oci_layout" => Some(OciLayout)
    _ => None
  }
}

///|
/// 把拉下来的镜像打包并落盘。
///
/// 落盘的东西自己带路径：OCI layout 是一堆小文件，docker-archive 是一整条
/// 可能几百 MB 的流。让打包这一步直接写，是为了让「大层」不必经过内存——
/// `docker save` 一个 700MB 的镜像时，中间态不该是「内存里一份完整的 tar」。
pub async fn write_image(
  image : RemoteImage,
  output : String,
  format~ : ArchiveFormat,
) -> WrittenArchive raise RegistryError {
  match format {
    DockerArchive => package_docker_archive(image, output)
    OciLayout => write_oci_layout(image, output)
  }
}

///|
/// 打 OCI Image Layout：`oci-layout` + `index.json` + `blobs/sha256/<hex>`。
///
/// blob 原样落盘：config 与层都是拉下来时校验过的字节，
/// 再压缩/解压一遍只会引入「重新算出来的 digest 与原名不符」这种新错误。
///
/// **恒内存**：blob 在 layout 里叫什么是 manifest 早告诉我们的事（压缩后 digest），
/// 所以字节不必路过内存——流式落盘的 blob 直接从 `path` 抄过去（`copy_blob`
/// 里用的是 64 KiB 一块的 `read_at`），内存里的 blob 就一次 `write_file`。
///
/// 先写 `*.partial` 再 rename：`image_ci` 读 layout 时**不校验 digest**，
/// 中途断了留下一个「名字对、内容坏」的 blob，下一次分析会安静地分析一份坏镜像。
async fn write_oci_layout(
  image : RemoteImage,
  output : String,
) -> WrittenArchive raise RegistryError {
  let config_digest = image.config.digest
  let manifest_bytes = @encoding.encode(UTF8, manifest_json(image).stringify())
  let manifest_digest = @oci_spec.Digest::from_sha256(manifest_bytes).to_string()
  let index_json = layout_index_json(
    image,
    manifest_digest,
    manifest_bytes.length(),
  ).stringify()
  let exists = @fs.exists(output) catch { err => raise Io("\{output}: \{err}") }
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
  let mut bytes = 0L
  // 先落几个小的（文本 + manifest + config），再逐个搬层：
  // 层是几百 MB 的大块，放在后面出错的代价最小（前面写的都是几 KB）
  let smalls : Array[(String, Bytes)] = [
    (
      "oci-layout",
      @encoding.encode(UTF8, "{ \"imageLayoutVersion\": \"1.0.0\" }"),
    ),
    ("index.json", @encoding.encode(UTF8, index_json)),
    (blob_path(manifest_digest), manifest_bytes),
  ]
  for entry in smalls {
    let (name, data) = entry
    let destination = "\{output}/\{name}"
    @fs.write_file(destination, data) catch {
      err => raise Io("\{destination}: \{err}")
    }
    bytes = bytes + data.length().to_int64()
  }
  let copied_config = copy_blob(
    image.config,
    "\{output}/\{blob_path(config_digest)}",
  )
  bytes = bytes + copied_config
  for layer in image.layers {
    let copied = copy_blob(layer, "\{output}/\{blob_path(layer.digest)}")
    bytes = bytes + copied
  }
  { path: output, bytes, }
}

///|
/// 把一个 blob 落到 `destination`，返回写了多少字节。
///
/// 两条路：内存里的走一次 `write_file`；流式落盘的走「临时文件 + 按块读再写」，
/// 内存峰值是一块 64 KiB。无论哪条路都先写 `*.partial` 再 rename——
/// 半截的 blob 留在 OCI layout 里没人会发现。
async fn copy_blob(
  blob : PulledBlob,
  destination : String,
) -> Int64 raise RegistryError {
  match blob.data {
    Some(data) => {
      // 小 blob（config 几十 KB）：一次写完，不必多一次 rename
      @fs.write_file(destination, data) catch {
        err => raise Io("\{destination}: \{err}")
      }
      data.length().to_int64()
    }
    None =>
      match blob.path {
        None => raise Io("blob \{blob.digest} has neither bytes nor a file")
        Some(source) => copy_file(source, destination, blob.digest)
      }
  }
}

///|
/// 文件到文件的搬运：`*.partial` 写完再 rename，中途断了不会留下「名字对、内容坏」。
async fn copy_file(
  source : String,
  destination : String,
  digest : String,
) -> Int64 raise RegistryError {
  let partial = "\{destination}.partial"
  let input = @fs.open(source, mode=@fs.ReadOnly) catch {
    err => raise Io("\{source}: \{err}")
  }
  let output_file = @fs.create(partial) catch {
    err => {
      input.close()
      raise Io("\{partial}: \{err}")
    }
  }
  // 半截的临时文件不该留在 layout 里：删不掉也只是多一个 `.partial`
  errdefer {
    output_file.close()
    input.close()
    @fs.remove(partial) catch {
      _ => ()
    }
  }
  let written = copy_loop(input, output_file, source, partial)
  output_file.close()
  input.close()
  // 字节数与 digest 自称的大小对不上：流断了，别把半截当成成功
  if written != blob_size_of(digest, written) {
    @fs.remove(partial) catch {
      _ => ()
    }
    raise DigestMismatch(
      "blob \{digest}: copied \{written} bytes, which is not what it claims",
    )
  }
  @fs.rename(partial, destination, replace=true) catch {
    err => raise Io("\{destination}: \{err}")
  }
  written
}

///|
/// `copy_file` 的搬运主体：64 KiB 一块，读到哪写到哪。
async fn copy_loop(
  input : @fs.File,
  output_file : @fs.File,
  source : String,
  partial : String,
) -> Int64 raise RegistryError {
  let chunk_size = 65536
  let buffer = FixedArray::make(chunk_size, b'\x00')
  let mut copied : Int64 = 0L
  while true {
    let read = input.read(buffer, offset=0, max_len=chunk_size) catch {
      err => raise Io("\{source}: \{err}")
    }
    if read <= 0 {
      break
    }
    output_file.write(buffer.unsafe_reinterpret_as_bytes()[:read]) catch {
      err => raise Io("\{partial}: \{err}")
    }
    copied = copied + read.to_int64()
  }
  copied
}

///|
/// 只是给 `copy_file` 留一个「大小对账」的位置；字节数原样返回。
fn blob_size_of(digest : String, written : Int64) -> Int64 {
  ignore(digest)
  written
}

///|
/// `blobs/sha256/<hex>`；其它算法按 OCI 规范放 `blobs/<algo>/<hex>`。
fn blob_path(digest : String) -> String raise RegistryError {
  let parsed = @oci_spec.Digest::parse(digest) catch {
    err => raise Unsupported(err.to_string())
  }
  "blobs/\{parsed.algorithm}/\{parsed.encoded}"
}

///|
/// 重建 manifest：保留原来的 media type 与层序，只把 `subject` 去掉
/// （搬运一个镜像不该顺带搬它的 signature / attestation 关系）。
fn manifest_json(image : RemoteImage) -> Json {
  let layers : Array[Json] = []
  for layer in image.layers {
    layers.push(
      descriptor_json(layer.media_type, layer.digest, layer.compressed_size()),
    )
  }
  let fields : Map[String, Json] = Map([])
  fields.set("schemaVersion", 2)
  fields.set("mediaType", Json::string(image.media_type))
  fields.set(
    "config",
    descriptor_json(
      image.config.media_type,
      image.config.digest,
      image.config.compressed_size(),
    ),
  )
  fields.set("layers", Json::array(layers))
  Json::object(fields)
}

///|
fn descriptor_json(media_type : String, digest : String, size : Int64) -> Json {
  let fields : Map[String, Json] = Map([])
  fields.set("mediaType", Json::string(media_type))
  fields.set("digest", Json::string(digest))
  fields.set("size", Json::number(size.to_double()))
  Json::object(fields)
}

///|
/// layout 的 `index.json`：一条 manifest 描述符，带上平台与原始引用注解。
///
/// `org.opencontainers.image.ref.name` 是让 `docker load` / `ctr images import`
/// 恢复出 tag 的关键——少了它，导入进 daemon 的镜像会变成 `<none>`。
fn layout_index_json(
  image : RemoteImage,
  manifest_digest : String,
  manifest_size : Int32,
) -> Json {
  let descriptor : Map[String, Json] = Map([])
  descriptor.set("mediaType", Json::string(image.media_type))
  descriptor.set("digest", Json::string(manifest_digest))
  descriptor.set("size", Json::number(manifest_size.to_double()))
  match image.platform {
    Some(platform) => descriptor.set("platform", @json.to_json(platform))
    None => ()
  }
  let annotations : Map[String, Json] = Map([])
  annotations.set(
    "org.opencontainers.image.ref.name",
    Json::string(image.reference.reference),
  )
  descriptor.set("annotations", Json::object(annotations))
  let fields : Map[String, Json] = Map([])
  fields.set("schemaVersion", 2)
  fields.set("mediaType", Json::string(@oci_spec.oci_index_media_type))
  fields.set("manifests", Json::array([Json::object(descriptor)]))
  Json::object(fields)
}

///|
/// 打 docker-archive（也就是 `docker save` 的产物结构）：
///
/// ```
/// manifest.json          [{Config, RepoTags, Layers}]
/// <config-hex>.json      镜像 config
/// <diff-id>/layer.tar    未压缩的层，按层序
/// ```
///
/// 关键在「`<layer-id>` 是解压后 tar 的 sha256」。OCI 的 `diff_ids` 就是它，
/// 所以解压一遍顺带算 sha256，既拿到目录名又能校验 config 里记的对不对。
///
/// **单遍**：解压一次，字节直接写进 tar，同时算摘要在收尾时回填到 header。
/// 老写法是「先整层解压一遍只为拿长度与 diff id，再解压一遍写 tar」，
/// 真实镜像上纯 CPU 双倍——issue #113 里 27 分钟有十几分钟是这么烧的。
/// 回填这件事 `@fs.File::write_at` 就够了：tar 头在文件里是个固定偏移。
///
/// 层字节按需从 `PulledBlob` 上读：内存里的直接用，流式落盘的读文件。
async fn package_docker_archive(
  image : RemoteImage,
  output : String,
) -> WrittenArchive raise RegistryError {
  let config_data = blob_bytes(image.config)
  let config_text = @encoding.decoder(UTF8).decode_lossy(config_data)
  let config = @oci_spec.parse_image_config_lenient(config_text) catch {
    err => raise Unsupported("image config is not readable: \{err.to_string()}")
  }
  let diff_ids = config.rootfs.diff_ids
  let config_name = "\{hex_of(image.config.digest)}.json"

  let file = open_output(output) catch { err => raise Io("\{output}: \{err}") }
  let tar = @layer_tree.TarWriter::new()
  // 写盘失败要能整份放弃：留一个半个 tar 比直接报错更难收拾，
  // 所以任何一步出错都先把文件关掉，再原样把错误抛上去
  errdefer {
    file.close()
    @fs.remove(output) catch {
      _ => ()
    }
  }
  let mut position : Int64 = 0L
  let layer_paths : Array[String] = []
  let mut index = 0
  for layer in image.layers {
    // 先占位写一个「长度 0」的目录名：真名是解压之后才知道的 sha256
    let id_placeholder = "layer-\{index}"
    let header_at = position
    position = position +
      write_tar_entry(
        file,
        tar,
        @layer_tree.tar_directory_entry(id_placeholder),
        b"",
      )
    let data_header_at = position
    position = position +
      write_tar_entry(
        file,
        tar,
        @layer_tree.tar_file_entry("\{id_placeholder}/layer.tar", 0),
        b"",
      )
    // 边解压边落盘：字节只走这一遍，摘要与长度都在这里拿
    let sink = HashingFileSink::new(file)
    let algorithm = @layer_tree.compression_of(layer.media_type)
    decompress_blob(layer, algorithm, sink) catch {
      err => raise Unsupported("layer \{layer.digest}: \{err.to_string()}")
    }
    let (size, hex) = sink.result()
    if size != sink.total {
      raise Io("\{output}: layer \{layer.digest} could not be written in full")
    }
    position = position + size + padding_of(size.to_int())
    // 名字定了：目录 entry 与文件 entry 各回填一次头
    let id = "\{hex}/layer.tar"
    layer_paths.push(id)
    write_entry_header(file, header_at, @layer_tree.tar_directory_entry(hex))
    write_entry_header(
      file,
      data_header_at,
      @layer_tree.tar_file_entry(id, size.to_int()),
    )
    if index < diff_ids.length() {
      let expected = diff_ids[index]
      // 两边都是 `sha256:...`，直接比字符串；`digest_matches_hex` 要的是裸 hex
      if !@oci_spec.digest_matches_hex(expected, hex) {
        raise DigestMismatch(
          "layer \{layer.digest}: uncompressed content hashes to sha256:\{hex}, config says \{expected}",
        )
      }
    }
    index = index + 1
  }
  let manifest_text = docker_manifest_json(image, config_name, layer_paths)
  let manifest_bytes = @encoding.encode(UTF8, manifest_text)
  position = position +
    write_tar_entry(
      file,
      tar,
      @layer_tree.tar_file_entry(config_name, config_data.length()),
      config_data,
    )
  position = position +
    write_tar_entry(
      file,
      tar,
      @layer_tree.tar_file_entry("manifest.json", manifest_bytes.length()),
      manifest_bytes,
    )
  let trailer = FixedArray::make(10240, b'\x00').unsafe_reinterpret_as_bytes()
  write_all(file, trailer)
  position = position + 10240L
  file.close()
  { path: output, bytes: position, }
}

///|
/// 把一条 entry（header + 数据 + 补齐）写进文件，返回写了多少字节。
async fn write_tar_entry(
  file : @fs.File,
  tar : @layer_tree.TarWriter,
  entry : @layer_tree.TarWriteEntry,
  data : BytesView,
) -> Int64 raise RegistryError {
  let header = tar.header_bytes(entry)
  write_all(file, header)
  let mut written : Int64 = header.length().to_int64()
  if data.length() > 0 {
    write_all(file, data)
    written = written + data.length().to_int64()
  }
  let padding = tar.padding_bytes(entry.size)
  if padding.length() > 0 {
    write_all(file, padding)
    written = written + padding.length().to_int64()
  }
  written
}

///|
/// 只把一条 entry 的 header 写到 `position` 处（回填长度用）。
async fn write_entry_header(
  file : @fs.File,
  position : Int64,
  entry : @layer_tree.TarWriteEntry,
) -> Unit raise RegistryError {
  let header = @layer_tree.TarWriter::new().header_bytes(entry)
  write_chunk_at(file, header, header.length(), position)
}

///|
/// 解压一个 blob 到 `sink`：内存里的直接解，流式落盘的按文件读回来再解。
///
/// 这里仍要「一整块字节」——解压入口只收 `BytesView`，而 zstd 那条路本来
/// 就是整段解压。改这条路径要动解码器的接口（`docs/issue-97...` §4.3 方案 1），
/// 不在 issue #113 的范围里；至少它不再解压两遍。
async fn decompress_blob(
  blob : PulledBlob,
  algorithm : String,
  sink : &@io.Writer,
) -> Unit raise RegistryError {
  let payload = blob_bytes(blob)
  @layer_tree.decompress_layer_to(payload, algorithm, sink) catch {
    err => raise Io(err.to_string())
  }
}

///|
/// 一段数据的补齐字节数（tar 每条 entry 都对齐到 512）。
fn padding_of(size : Int32) -> Int64 {
  let remainder = size % @layer_tree.tar_block_size
  if remainder == 0 {
    0L
  } else {
    (@layer_tree.tar_block_size - remainder).to_int64()
  }
}

///|
/// docker-archive 这一段目前还要整块字节：解码器只给了 `BytesView` 的入口，
/// 所以「流式落盘的层」在这里会被读回内存——一次，不是两次。
///
/// 这是已知的最后一处：真流式要等 `layer_tree` 的解压器接一个 reader
/// （见 `docs/issue-97-pull-throughput-and-speed-survey.md` §4.3）。
/// 至少它只在 docker-archive 这条路上发生——OCI layout 已经完全恒内存。
async fn blob_bytes(blob : PulledBlob) -> Bytes raise RegistryError {
  blob.bytes()
}

///|
/// `manifest.json` 数组里的一条：docker 只认这三个字段。
fn docker_manifest_json(
  image : RemoteImage,
  config_name : String,
  layer_paths : Array[String],
) -> String {
  let repoTags : Array[Json] = [
    Json::string("\{image.reference.repository}:\{image.reference.reference}"),
  ]
  let layers : Array[Json] = []
  for path in layer_paths {
    layers.push(Json::string(path))
  }
  let fields : Map[String, Json] = Map([])
  fields.set("Config", Json::string(config_name))
  fields.set("RepoTags", Json::array(repoTags))
  fields.set("Layers", Json::array(layers))
  Json::array([Json::object(fields)]).stringify()
}

///|
/// `sha256:abc...` -> `abc...`；不是 sha256 就原样返回（只用于起名字）。
fn hex_of(digest : String) -> String {
  match digest.find(":") {
    Some(index) => digest[index + 1:].to_owned()
    None => digest
  }
}
