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
  let files : Array[(String, Bytes)] = [
    (
      "oci-layout",
      @encoding.encode(UTF8, "{ \"imageLayoutVersion\": \"1.0.0\" }"),
    ),
    ("index.json", @encoding.encode(UTF8, index_json)),
    (blob_path(manifest_digest), manifest_bytes),
    (blob_path(config_digest), image.config.data),
  ]
  for layer in image.layers {
    files.push((blob_path(layer.digest), layer.data))
  }
  let mut bytes = 0L
  for entry in files {
    let (name, data) = entry
    let destination = "\{output}/\{name}"
    @fs.write_file(destination, data) catch {
      err => raise Io("\{destination}: \{err}")
    }
    bytes = bytes + data.length().to_int64()
  }
  { path: output, bytes, }
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
///
/// **边解压边写盘**，不留中间产物：tar 要写多大由每一层的**未压缩**长度决定，
/// 而这些长度在解压之前谁也说不准（gzip 的 ISIZE 有，但那是校验字段，
/// 信不过）。所以先按「层头 + 占位长度」的顺序流式写，写完回填。
///
/// 老写法是「解压出一整层 → 整段塞进 TarWriter 的 Buffer → 最后 to_bytes」，
/// 700MB 的层等于同时在内存里放三份（压缩、解压、打包），
/// 打包那一步先撞上 Int32 缓冲边界（issue #97 的 `Buffer capacity overflow`）。
async fn package_docker_archive(
  image : RemoteImage,
  output : String,
) -> WrittenArchive raise RegistryError {
  let config_text = @encoding.decoder(UTF8).decode_lossy(image.config.data)
  let config = @oci_spec.parse_image_config_lenient(config_text) catch {
    err => raise Unsupported("image config is not readable: \{err.to_string()}")
  }
  let diff_ids = config.rootfs.diff_ids
  // 先拿到每层解压后的 diff id 与长度：tar 头里的 size 是要写死的，
  // 而解压出来的长度只有解过才知道。代价是流式解一遍并算 sha256，
  // 但这一步本来就要做（`<layer-id>` 就是它）。
  let plans : Array[LayerPlan] = []
  for index, layer in image.layers {
    let algorithm = @layer_tree.compression_of(layer.media_type)
    let probe = HashingWriter::new()
    @layer_tree.decompress_layer_to(layer.data, algorithm, probe) catch {
      err => raise Unsupported("layer \{layer.digest}: \{err.to_string()}")
    }
    let (size, hex) = probe.result()
    let actual = "sha256:\{hex}"
    if index < diff_ids.length() {
      let expected = diff_ids[index]
      // 两边都是 `sha256:...`，直接比字符串；`digest_matches_hex` 要的是裸 hex
      if !@oci_spec.digest_matches_hex(expected, hex) {
        raise DigestMismatch(
          "layer \{layer.digest}: uncompressed content hashes to \{actual}, config says \{expected}",
        )
      }
    }
    plans.push({ id: hex, size, layer, })
  }
  let layer_paths : Array[String] = []
  for plan in plans {
    layer_paths.push("\{plan.id}/layer.tar")
  }
  let config_name = "\{hex_of(image.config.digest)}.json"
  let manifest_text = docker_manifest_json(image, config_name, layer_paths)
  let manifest_bytes = @encoding.encode(UTF8, manifest_text)

  let tar = @layer_tree.TarWriter::new()
  let file = open_output(output) catch { err => raise Io("\{output}: \{err}") }
  let sink = CountingWriter::new(file)
  // 写盘失败要能整份放弃：留一个半个 tar 比直接报错更难收拾。
  // 所以任何一步出错都先把文件关掉，再原样把错误抛上去。
  try {
    // 每层：目录 entry + 层内容（第二次解压，这次直接写进 tar）
    for plan in plans {
      tar.write_entry(sink, @layer_tree.tar_directory_entry(plan.id), b"")
      tar.begin(
        sink,
        @layer_tree.tar_file_entry("\{plan.id}/layer.tar", plan.size),
      )
      let before = sink.written()
      let algorithm = @layer_tree.compression_of(plan.layer.media_type)
      @layer_tree.decompress_layer_to(plan.layer.data, algorithm, sink) catch {
        err =>
          raise Unsupported("layer \{plan.layer.digest}: \{err.to_string()}")
      }
      // 头里的 size 是写死的，实际写多了/少了都会让后面的 header 错位，
      // 与其产出一个「能读但内容错位」的 tar，不如当场报
      let actual = sink.written() - before
      if actual != plan.size.to_int64() {
        raise Io(
          "\{output}: layer \{plan.layer.digest} unpacked to \{actual} bytes, header says \{plan.size}",
        )
      }
      tar.pad(sink, plan.size)
    }
    tar.write_entry(
      sink,
      @layer_tree.tar_file_entry(config_name, image.config.data.length()),
      image.config.data,
    )
    tar.write_entry(
      sink,
      @layer_tree.tar_file_entry("manifest.json", manifest_bytes.length()),
      manifest_bytes,
    )
    tar.finish(sink)
  } catch {
    err => {
      sink.close()
      raise Io("\{output}: \{err.to_string()}")
    }
  }
  let bytes = sink.written()
  sink.close()
  { path: output, bytes, }
}

///|
/// 一层的打包计划：目录名（未压缩 tar 的 sha256）、未压缩长度、原始 blob。
priv struct LayerPlan {
  id : String
  size : Int32
  layer : PulledBlob
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
