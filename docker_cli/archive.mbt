///|
/// `docker save` 产出的 docker-archive 格式的目录结构（不含内容）。
///
/// 格式：根下 `manifest.json` 数组 + 每个镜像一个 `<config-digest>.json`
/// 加若干个 `<layer-id>/layer.tar`（老格式）或 `<blob-sha256>.tar`（新版）。
/// 我们只解析出「谁是谁」，把层内容留给 P2 按需取。
pub(all) struct DockerArchive {
  /// `manifest.json` 里的条目，通常一个镜像一条
  entries : Array[DockerArchiveEntry]
} derive(Eq, Debug)

///|
pub extend DockerArchive with Eq::{equal, not_equal}

///|
pub extend DockerArchive with @debug.Debug::{to_repr}

///|
/// 一条 docker-archive 记录。
pub(all) struct DockerArchiveEntry {
  /// 镜像引用的 Config 字段，形如 `<hex>.json`
  config : String
  /// 仓库标签，形如 `nginx:latest`；`docker save -o` 时可能为空
  repoTags : Array[String]
  /// 每层的 tar 路径，按层序排列（未压缩）
  layers : Array[String]
  /// 层 ID（`<id>/layer.tar` 里的 `<id>` 部分）
  layer_ids : Array[String]
} derive(Eq, Debug)

///|
pub extend DockerArchiveEntry with Eq::{equal, not_equal}

///|
pub extend DockerArchiveEntry with @debug.Debug::{to_repr}

///|
/// 从整段归档字节里解析 `manifest.json`。
///
/// 这里走完整 tar 解析（`layer_tree` 的 `TarReader`），
/// 因为 docker-archive 的 tar 是未压缩的，不需要先解压。
pub fn parse_docker_archive(
  archive : BytesView,
) -> DockerArchive raise DockerCliError {
  let text = read_tar_entry_text(archive, "manifest.json") catch {
    err => raise Archive(err.to_string())
  }
  let manifest = match text {
    Some(text) => text
    None => raise Archive("archive has no manifest.json")
  }
  parse_manifest_json(manifest)
}

///|
/// 从 tar 里按路径取一条 entry 的文本内容。
fn read_tar_entry_text(
  archive : BytesView,
  path : String,
) -> String? raise @layer_tree.TarError {
  let reader = @layer_tree.TarReader::new(archive)
  while true {
    let entry = match reader.next() {
      None => break
      Some(entry) => entry
    }
    let name = match @layer_tree.normalize_path(entry.path) {
      Ok(name) => name
      Err(_) => continue
    }
    if name == path || name == "/\{path}" {
      let data = entry.data(archive)
      return Some(bytes_to_text(data))
    }
  }
  None
}

///|
/// `manifest.json` 是一个数组，每项含 `Config` / `RepoTags` / `Layers`。
fn parse_manifest_json(text : String) -> DockerArchive raise DockerCliError {
  let json = @json.parse(text) catch {
    err => raise Archive("manifest.json is not valid JSON: \{err}")
  }
  let items = match json {
    Array(items) => items
    _ => raise Archive("manifest.json is not an array")
  }
  let entries = []
  for item in items {
    let fields = match item {
      Object(fields) => fields
      _ => raise Archive("manifest.json entry is not an object")
    }
    let config = string_of(fields.get("Config"))
    let repoTags = string_array_of(fields.get("RepoTags"))
    let layers = string_array_of(fields.get("Layers"))
    let layer_ids = []
    for layer in layers {
      layer_ids.push(layer_id_of(layer))
    }
    entries.push({ config, repoTags, layers, layer_ids, })
  }
  { entries, }
}

///|
fn string_of(json : Json?) -> String {
  match json {
    Some(String(value)) => value
    _ => ""
  }
}

///|
fn string_array_of(json : Json?) -> Array[String] {
  match json {
    Some(Array(items)) => {
      let strings = []
      for item in items {
        match item {
          String(value) => strings.push(value)
          _ => ()
        }
      }
      strings
    }
    _ => []
  }
}

///|
/// `<hex>/layer.tar` → `<hex>`；新版 `blobs/sha256/<hex>` 也归一到 `<hex>`。
pub fn layer_id_of(layer_path : String) -> String {
  let trimmed = if layer_path.has_prefix("/") {
    layer_path[1:].to_owned()
  } else {
    layer_path
  }
  let segments = []
  for part in trimmed.split("/") {
    segments.push(part)
  }
  // 取最后一个不是 "layer.tar" 的段
  let mut id = ""
  for segment in segments {
    if segment != "layer.tar" && !segment.is_empty() {
      id = segment.to_owned()
    }
  }
  id
}

///|
/// `BytesView` → `String`。manifest.json 是 UTF-8，
/// lossy 解码保证尾部填充字节不会让解析失败。
pub fn bytes_to_text(data : BytesView) -> String {
  @utf8.decode_lossy(data)
}
