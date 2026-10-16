///|
/// OCI / AUFS whiteout 前缀：`.wh.<name>` 表示删除同目录下的 `<name>`。
pub let whiteout_prefix : String = ".wh."

///|
/// overlayfs 的 opaque 标记：`.wh..wh..opq` 表示这一层把该目录内容整体替换。
pub let opaque_marker : String = ".wh..wh..opq"

///|
/// AUFS 的 plnk 标记：`.wh..wh..plnk`。它删除的是 plnk 目录下的
/// `.wh.<inode>` 文件，不直接对应被删条目，因此识别出来但不落到树上。
pub let plnk_marker : String = ".wh..wh..plnk"

///|
/// whiteout 条目的语义分类。
pub(all) enum WhiteoutKind {
  /// `.wh.<name>`：删除同目录下名为 `<name>` 的条目
  Entry(String)
  /// `.wh..wh..opq`：该目录变成 opaque，只保留本层写入的内容
  Opaque
  /// `.wh..wh..plnk`：硬链接维护文件，忽略
  Plnk
} derive(Eq, Debug)

///|
pub extend WhiteoutKind with Eq::{equal, not_equal}

///|
pub extend WhiteoutKind with @debug.Debug::{to_repr}

///|
pub impl Show for WhiteoutKind with fn to_string(self) {
  match self {
    Entry(name) => "whiteout entry \{name}"
    Opaque => "opaque directory"
    Plnk => "plnk marker (ignored)"
  }
}

///|
pub extend WhiteoutKind with Show::{to_string, output}

///|
/// 判断 tar entry 名是否是 whiteout，并给出语义分类。
///
/// 只看路径最后一段：`.wh.` 前缀在文件名里才生效，出现在中间段属于普通目录名。
pub fn whiteout_kind(raw : String) -> WhiteoutKind? {
  let name = base_name(raw)
  if name == opaque_marker {
    return Some(Opaque)
  }
  if name == plnk_marker {
    return Some(Plnk)
  }
  if name.has_prefix(whiteout_prefix) {
    let target = name[whiteout_prefix.length():].to_owned()
    if target.is_empty() {
      return None
    }
    return Some(Entry(target))
  }
  None
}

///|
/// 把一层 tar 应用到文件树。`layer` 是该层的下标（从 0 开始）。
///
/// 语义要点：
/// - 目录 entry 只建/更新目录节点；文件 entry 缺父目录时按需补建，
///   再靠 `promote_orphans` 把先到的子节点挂回去
/// - `.wh.<name>` 删除同目录条目；`.wh..wh..opq` 清空目录已有内容
/// - 硬链接登记为 `Hardlink(target)`，软链接记录目标但不跟随
pub fn apply_layer(
  tree : FileTree,
  stream : BytesView,
  layer : Int32,
) -> Unit raise TarError {
  let reader = TarReader::new(stream)
  // opaque 目录要在本层所有 entry 应用完后才清空，否则同层后续写入会被误删
  let opaque_dirs : Array[String] = []
  while true {
    let entry = match reader.next() {
      None => break
      Some(entry) => entry
    }
    let path = match normalize_path(entry.path) {
      Err(_) => continue // 逃逸出根的 entry 直接丢弃，不污染树
      Ok(path) => path
    }
    match whiteout_kind(path) {
      Some(WhiteoutKind::Entry(name)) => {
        let target = join_path(parent_path(path), name)
        remove_subtree(tree, target, layer) |> ignore
        continue
      }
      Some(WhiteoutKind::Opaque) => {
        opaque_dirs.push(parent_path(path))
        continue
      }
      Some(WhiteoutKind::Plnk) => continue
      None => ()
    }
    match entry.entry_type {
      Meta | Other(_) => continue
      _ => apply_entry(tree, path, entry, layer)
    }
  }
  for directory in opaque_dirs {
    make_opaque(tree, directory, layer)
  }
  tree.promote_orphans()
  tree.layers = layer + 1
}

///|
/// 把一条普通 entry 落到树上。
fn apply_entry(
  tree : FileTree,
  path : String,
  entry : TarEntry,
  layer : Int32,
) -> Unit {
  if path == "/" {
    return
  }
  let kind = match entry.entry_type {
    TarEntryType::Directory => NodeKind::Directory
    TarEntryType::Symlink => NodeKind::Symlink(entry.link_target)
    TarEntryType::Hardlink =>
      NodeKind::Hardlink(resolve_hardlink_target(path, entry.link_target))
    _ => NodeKind::File
  }
  let size = if entry.entry_type is TarEntryType::Regular {
    entry.size
  } else {
    0
  }
  let mode = if entry.mode == 0 { default_mode(kind) } else { entry.mode }
  // 先补父目录，节点才挂得进正确的父节点；否则只能进 orphans、丢失排序
  tree.ensure_parents(path, layer)
  match tree.nodes.get(path) {
    Some(node) => {
      node.kind = kind
      node.size = size
      node.mode = mode
      node.uid = entry.uid
      node.gid = entry.gid
      node.layer = layer
      node.mtime = entry.mtime
    }
    None => {
      let node = Node::new(
        path,
        kind,
        size~,
        mode~,
        uid=entry.uid,
        gid=entry.gid,
        layer~,
        mtime=entry.mtime,
      )
      tree.nodes.set(path, node)
      tree.attach(node)
    }
  }
  tree.bump_stat(layer, size, 0)
  tree.record(path, { layer, kind, size, })
}

///|
/// 没有权限信息时的兜底权限。
fn default_mode(kind : NodeKind) -> Int32 {
  match kind {
    Directory => 0o755
    _ => 0o644
  }
}

///|
/// 硬链接目标：tar 里的 linkname 相对当前 entry 所在目录解析，与文件名无关。
fn resolve_hardlink_target(path : String, linkname : String) -> String {
  if linkname.is_empty() {
    return path
  }
  if linkname.has_prefix("/") {
    match normalize_path(linkname) {
      Ok(target) => target
      Err(_) => linkname
    }
  } else {
    join_path(parent_path(path), linkname)
  }
}

///|
/// 累加某层的变更统计。
fn FileTree::bump_stat(
  self : FileTree,
  layer : Int32,
  bytes : Int32,
  deleted : Int32,
) -> Unit {
  while self.layer_stats.length() <= layer {
    let index = self.layer_stats.length()
    self.layer_stats.push({
      layer: index,
      changed_paths: 0,
      changed_bytes: 0,
      deleted_paths: 0,
    })
  }
  let stat = self.layer_stats[layer]
  if bytes != 0 || deleted == 0 {
    stat.changed_paths = stat.changed_paths + 1
  }
  stat.changed_bytes = stat.changed_bytes + bytes
  stat.deleted_paths = stat.deleted_paths + deleted
}

///|
/// 把节点挂到父目录下；父目录还不在树上时先寄存到 `orphans`。
fn FileTree::attach(self : FileTree, node : Node) -> Unit {
  if node.path == "/" {
    return
  }
  let parent_path_value = parent_path(node.path)
  match self.nodes.get(parent_path_value) {
    Some(parent) => parent.insert_child(node)
    None => {
      let bucket = match self.orphans.get(parent_path_value) {
        Some(bucket) => bucket
        None => {
          let bucket = []
          self.orphans.set(parent_path_value, bucket)
          bucket
        }
      }
      bucket.push(node)
    }
  }
}

///|
/// 补齐路径上的父目录（tar 里目录 entry 可能缺席）。
fn FileTree::ensure_parents(
  self : FileTree,
  path : String,
  layer : Int32,
) -> Unit {
  let mut current = parent_path(path)
  while current != "/" && !self.nodes.contains(current) {
    let node = Node::new(current, Directory, mode=0o755, layer~)
    self.nodes.set(current, node)
    self.attach(node)
    current = parent_path(current)
  }
}

///|
/// 把寄存的子节点挂到父目录下，保持 `children` 有序。
///
/// 父目录可能是后来才出现的（甚至由 `ensure_parents` 补建），
/// 因此这里要反复推进：挂完一轮后可能又有新父目录变得可用了。
fn FileTree::promote_orphans(self : FileTree) -> Unit {
  let mut pending = self.orphans
  self.orphans = Map([])
  while pending.length() > 0 {
    let next : Map[String, Array[Node]] = Map([])
    for parent, children in pending {
      match self.nodes.get(parent) {
        Some(parent_node) =>
          for child in children {
            parent_node.insert_child(child)
          }
        None => next.set(parent, children)
      }
    }
    // 一轮下来没有任何进展就跳出，避免无谓的循环
    if next.length() == pending.length() {
      self.orphans = next
      return
    }
    pending = next
  }
}

///|
/// 删除 `path` 及其子树，返回被删除的路径数。
///
/// 删除会一并清掉孤儿子节点表里的残留，避免后续 `promote_orphans` 复活已删节点。
pub fn remove_subtree(tree : FileTree, path : String, layer : Int32) -> Int32 {
  if path == "/" {
    return 0
  }
  let doomed = tree.collect_subtree(path)
  if doomed.is_empty() {
    return 0
  }
  for node_path in doomed {
    tree.nodes.remove(node_path) |> ignore
    tree.orphans.remove(node_path) |> ignore
  }
  // 从父目录里摘掉被删的根节点
  match tree.nodes.get(parent_path(path)) {
    Some(parent) => parent.remove_child(path) |> ignore
    None => ()
  }
  tree.clear_layers_from(path, layer)
  tree.bump_stat(layer, 0, doomed.length())
  tree.record(path, { layer, kind: File, size: 0, })
  doomed.length()
}

///|
/// 收集 `path` 及子树内所有路径。
fn FileTree::collect_subtree(self : FileTree, path : String) -> Array[String] {
  let result = []
  if self.nodes.get(path) is Some(_) {
    result.push(path)
  }
  let prefix = if path == "/" { "" } else { path }
  for node_path, _ in self.nodes {
    if node_path != "/" && node_path != path && path_is_under(node_path, prefix) {
      result.push(node_path)
    }
  }
  result
}

///|
/// 子树被删后，仍有层记录指向这些路径的话，把它们的存在层号清成被删层。
///
/// 目的是让 `tree[node].layer` 表达「最后一次有效写入」而不是指向一个已消失的层。
fn FileTree::clear_layers_from(
  self : FileTree,
  path : String,
  layer : Int32,
) -> Unit {
  for node_path, node in self.nodes {
    if path_is_under(node_path, path) && node.layer >= layer {
      node.layer = layer
    }
  }
}

///|
/// opaque 语义：目录内容在本层被整体替换，抹掉本层没有重新写入的旧条目。
///
/// `.wh..wh..opq` 自身出现在该目录下，本层写过的条目一律保留；
/// 其余旧条目连同子树删除。
pub fn make_opaque(tree : FileTree, directory : String, layer : Int32) -> Unit {
  let doomed : Array[String] = []
  let prefix = if directory == "/" { "" } else { directory }
  for node_path, node in tree.nodes {
    if node_path == "/" {
      continue
    }
    let under = if prefix == "" {
      true
    } else {
      path_is_under(node_path, prefix)
    }
    if !under {
      continue
    }
    let parent = parent_path(node_path)
    if parent != directory {
      continue
    }
    if node.layer < layer {
      doomed.push(node_path)
    }
  }
  for node_path in doomed {
    remove_subtree(tree, node_path, layer) |> ignore
  }
}

///|
/// 按压缩方式解压一层的数据。`algorithm` 取 `"none"` / `"gzip"`。
pub fn decompress_layer(
  data : BytesView,
  algorithm : String,
) -> Bytes raise DecompressError {
  match algorithm {
    "" | "none" => data.to_owned()
    "gzip" => gzip_decompress(data)
    _ => raise Unsupported(algorithm)
  }
}

///|
/// 解压并按 media type 推断压缩方式后应用到树上。
pub fn apply_layer_with_media_type(
  tree : FileTree,
  data : BytesView,
  media_type : String,
  layer : Int32,
) -> Unit raise LayerError {
  let algorithm = compression_of(media_type)
  let raw = decompress_layer(data, algorithm) catch {
    err => raise Decompress(err)
  }
  apply_layer(tree, raw, layer) catch {
    err => raise Tar(err)
  }
}

///|
/// 从 OCI media type 推断层的压缩方式。
pub fn compression_of(media_type : String) -> String {
  if media_type.has_suffix("+gzip") || media_type.has_suffix(".gzip") {
    "gzip"
  } else if media_type.has_suffix("+zstd") {
    "zstd"
  } else {
    "none"
  }
}
