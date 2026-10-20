///|
/// docker-archive 里的一层：从归档里按路径取出、必要时解压后的 tar 字节。
pub(all) struct ArchiveLayer {
  /// 在 `manifest.json` 里的路径
  path : String
  /// 未压缩的 tar 字节（docker-archive 的 `layer.tar` 本身就是未压缩的）
  bytes : Bytes
} derive(Debug)

///|
pub extend ArchiveLayer with @debug.Debug::{to_repr}

///|
/// 把 docker-archive 按层拆开，顺序与 `manifest.json` 的 `Layers` 一致。
///
/// 这是 issue #17 验收里「`docker save` 出来的 tar 能被 P2 的
/// `apply_layers_with_diffs` 直接吃下」这一步的桥：
/// docker-archive 的层是未压缩 tar，直接喂给 P2 即可，不需要再解压。
pub fn extract_layers(
  archive : BytesView,
  entry : DockerArchiveEntry,
  on_layer~ : (ArchiveLayer) -> Unit = fn(_) { () },
) -> Array[ArchiveLayer] raise DockerCliError {
  let layers = []
  for path in entry.layers {
    let data = read_entry_bytes(archive, path)
    match data {
      Some(bytes) => {
        let layer = { path, bytes, }
        // 一层解出来的那一刻就交出去：几百 MB 的层读完要几秒，
        // 等全部读完再统一报，用户看到的就是「保存完了，然后什么都没发生」。
        on_layer(layer)
        layers.push(layer)
      }
      None => raise Archive("manifest.json references a missing layer: \{path}")
    }
  }
  layers
}

///|
/// 取归档里第一个镜像条目。单镜像的 `docker save` 是最常见形态，
/// 多镜像归档（`docker save a b`）留给调用方自己遍历 `entries`。
pub fn primary_entry(archive : DockerArchive) -> DockerArchiveEntry? {
  match archive.entries {
    [first, ..] => Some(first)
    [] => None
  }
}

///|
/// 从 tar 里按路径取一条 entry 的原始字节。
fn read_entry_bytes(
  archive : BytesView,
  path : String,
) -> Bytes? raise DockerCliError {
  let reader = @layer_tree.TarReader::new(archive)
  while true {
    let entry = reader.next() catch {
      err => {
        if err is @layer_tree.TarError::NotFound {
          break
        }
        raise Archive(err.to_string())
      }
    }
    let name = @layer_tree.normalize_path(entry.path) catch { _ => continue }
    if name == path || name == "/\{path}" {
      return Some(entry.data(archive).to_owned())
    }
  }
  None
}
