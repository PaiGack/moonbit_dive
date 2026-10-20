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
/// 打包出来的一份产物：`files` 是 `相对路径 -> 字节`。
///
/// 不做「边下边写盘」是因为镜像拉完才谈得上打包（manifest 决定层序），
/// 而写盘失败要能整份放弃——留一堆半个文件比直接报错更难收拾。
/// 内存代价是镜像的压缩体积，与 `docker save` 时 daemon 的表现一个量级。
pub(all) struct ArchiveBundle {
  /// `main` 是 tar 字节（docker-archive），`tree` 是目录里的文件（OCI layout）
  files : Array[(String, Bytes)]
  format : ArchiveFormat
} derive(Eq, Debug)

///|
pub extend ArchiveBundle with Eq::{equal, not_equal}

///|
pub extend ArchiveBundle with @debug.Debug::{to_repr}

///|
/// 把所有文件的字节加起来（打印用）。
pub fn ArchiveBundle::total_size(self : ArchiveBundle) -> Int32 {
  let mut total = 0
  for entry in self.files {
    total = total + entry.1.length()
  }
  total
}

///|
/// 把拉下来的镜像打成指定格式。
pub fn package_image(
  image : RemoteImage,
  format~ : ArchiveFormat,
) -> ArchiveBundle raise RegistryError {
  match format {
    DockerArchive => package_docker_archive(image)
    OciLayout => package_oci_layout(image)
  }
}

///|
/// 打 OCI Image Layout：`oci-layout` + `index.json` + `blobs/sha256/<hex>`。
///
/// blob 原样落盘：config 与层都是拉下来时校验过的字节，
/// 再压缩/解压一遍只会引入「重新算出来的 digest 与原名不符」这种新错误。
fn package_oci_layout(image : RemoteImage) -> ArchiveBundle raise RegistryError {
  let files : Array[(String, Bytes)] = []
  let config_digest = image.config.digest
  let manifest_bytes = @encoding.encode(UTF8, manifest_json(image).stringify())
  let manifest_digest = @oci_spec.Digest::from_sha256(manifest_bytes).to_string()
  let index_json = layout_index_json(
    image,
    manifest_digest,
    manifest_bytes.length(),
  ).stringify()
  files.push(
    (
      "oci-layout",
      @encoding.encode(UTF8, "{ \"imageLayoutVersion\": \"1.0.0\" }"),
    ),
  )
  files.push(("index.json", @encoding.encode(UTF8, index_json)))
  files.push((blob_path(manifest_digest), manifest_bytes))
  files.push((blob_path(config_digest), image.config.data))
  for layer in image.layers {
    files.push((blob_path(layer.digest), layer.data))
  }
  { files, format: OciLayout, }
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
      descriptor_json(layer.media_type, layer.digest, layer.data.length()),
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
      image.config.data.length(),
    ),
  )
  fields.set("layers", Json::array(layers))
  Json::object(fields)
}

///|
fn descriptor_json(media_type : String, digest : String, size : Int32) -> Json {
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
/// 所以解压一遍顺带算 sha256，既拿到目录名又能校验 config 里记的对不对——
/// 对不上说明层被换了，这时候打包出来的还是会被拒绝加载，不如当场报。
fn package_docker_archive(
  image : RemoteImage,
) -> ArchiveBundle raise RegistryError {
  let config_text = @encoding.decoder(UTF8).decode_lossy(image.config.data)
  let config = @oci_spec.parse_image_config_lenient(config_text) catch {
    err => raise Unsupported("image config is not readable: \{err.to_string()}")
  }
  let diff_ids = config.rootfs.diff_ids
  let writer = @layer_tree.TarWriter::new()
  let layer_paths : Array[String] = []
  for index, layer in image.layers {
    let algorithm = @layer_tree.compression_of(layer.media_type)
    let raw = @layer_tree.decompress_layer(layer.data, algorithm) catch {
      err => raise Unsupported("layer \{layer.digest}: \{err.to_string()}")
    }
    let actual = @oci_spec.Digest::from_sha256(raw).to_string()
    if index < diff_ids.length() {
      let expected = diff_ids[index]
      // 两边都是 `sha256:...`，直接比字符串；`digest_matches_hex` 要的是裸 hex
      if !@oci_spec.digest_matches_hex(expected, hex_of(actual)) {
        raise DigestMismatch(
          "layer \{layer.digest}: uncompressed content hashes to \{actual}, config says \{expected}",
        )
      }
    }
    // 目录名用算出来的 diff id：config 缺 diff_ids 时也只有它是对的
    let id = hex_of(actual)
    let layer_path = "\{id}/layer.tar"
    layer_paths.push(layer_path)
    // 目录 entry 不是必需的，但解压工具靠它建目录；补一条省得 tar 实现各显神通
    writer.write_entry(@layer_tree.tar_directory_entry(id), b"")
    writer.write_entry(
      @layer_tree.tar_file_entry(layer_path, raw.length()),
      raw,
    )
  }
  let config_name = "\{hex_of(image.config.digest)}.json"
  writer.write_entry(
    @layer_tree.tar_file_entry(config_name, image.config.data.length()),
    image.config.data,
  )
  writer.write_entry(
    @layer_tree.tar_file_entry(
      "manifest.json",
      @encoding.encode(
        UTF8,
        docker_manifest_json(image, config_name, layer_paths),
      ).length(),
    ),
    @encoding.encode(
      UTF8,
      docker_manifest_json(image, config_name, layer_paths),
    ),
  )
  let tar = writer.finish()
  { files: [("docker-archive.tar", tar)], format: DockerArchive, }
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
