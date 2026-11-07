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
#derive(Eq, Debug)
pub(all) enum WhiteoutKind {
  /// `.wh.<name>`：删除同目录下名为 `<name>` 的条目
  Entry(String)
  /// `.wh..wh..opq`：该目录变成 opaque，只保留本层写入的内容
  Opaque
  /// `.wh..wh..plnk`：硬链接维护文件，忽略
  Plnk
}

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
///
/// 关键约束：层的效果与层内条目顺序无关，判定一律看节点的**来层**
/// （`node.info.layer`），而不是看谁先谁后：
/// - whiteout 只删除来层早于本层的条目，本层重新写入的同名条目予以保留
/// - opaque 目录删掉本层没有子条目的旧子树
/// - whiteout / opaque 带来的删除先记下来，等整层扫完再一次性落到树上
pub fn apply_layer(
  tree : FileTree,
  stream : BytesView,
  layer : Int32,
) -> Unit raise TarError {
  let reader = TarReader::new(stream)
  // 本层 deletions 要等扫完再落地：whiteout 条目可能排在被删文件之前，
  // 提前删掉会把本层重新写入的内容一起带走
  let deletions : Array[String] = []
  let opaque_dirs : Array[String] = []
  while true {
    // 读完（`NotFound`）就是正常出口，其它错误照旧往上抛
    let entry = reader.next() catch {
      err => if err is NotFound { break } else { raise err }
    }
    // 逃逸出根的 entry 直接丢弃，不污染树
    let path = normalize_path(entry.path) catch { _ => continue }
    match whiteout_kind(path) {
      Some(WhiteoutKind::Entry(name)) => {
        deletions.push(join_path(parent_path(path), name))
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
  for target in deletions {
    remove_prior_entry(tree, target, layer)
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
      // 覆写 = 换一份 info 再换掉 `nodes` 里那一份；旧节点原样留给快照
      let next = node.overwrite(
        kind,
        size~,
        mode~,
        uid=entry.uid,
        gid=entry.gid,
        layer~,
        mtime=entry.mtime,
      )
      tree.set(next)
      tree.relink_parent(path)
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
    normalize_path(linkname) catch {
      _ => linkname
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
/// 把一个还没有父目录挂在树里的节点挂上去；父目录也不在树上时先寄存到 `orphans`。
///
/// 挂上去会换掉父目录那一份节点（`children` 是新的），所以父目录的父目录
/// 也得跟着换——一路换到根。这是「节点不可变」在挂载上的全部代价。
fn FileTree::attach(self : FileTree, node : Node) -> Unit {
  if node.path == "/" {
    return
  }
  let parent_path_value = parent_path(node.path)
  if self.nodes.contains(parent_path_value) {
    self.relink_parent(node.path)
  } else {
    self.park(node, parent_path_value)
  }
}

///|
/// 把节点寄存在 `orphans` 里等父目录出现。
fn FileTree::park(self : FileTree, node : Node, parent : String) -> Unit {
  let bucket = match self.orphans.get(parent) {
    Some(bucket) => bucket
    None => {
      let bucket = []
      self.orphans.set(parent, bucket)
      bucket
    }
  }
  bucket.push(node)
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
    // 自深向浅补：每一层补完就挂进已经存在的父目录；父目录也缺就先寄存，
    // 下一轮补出它来再挂回去（`promote_orphans` 只看「父目录在不在树上」）
    let parent = parent_path(current)
    if self.nodes.contains(parent) {
      self.relink_parent(current)
    } else {
      self.park(node, parent)
    }
    current = parent
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
      if !self.nodes.contains(parent) {
        next.set(parent, children)
        continue
      }
      // 存活的父目录里挨个重挂：`relink_parent` 自己会摘旧插新，
      // 重复的孤儿（同一路径出现两次）不会变成两个子节点
      for child in children {
        self.relink_parent(child.path)
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
  tree.detach_parent(path)
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
/// `path` 自身或子树里是否有「来层不早于 `layer`」的条目。
///
/// opaque 判定用它回答「这段旧内容在本层有没有被重新写过」。
fn FileTree::has_descendant_from(
  self : FileTree,
  path : String,
  layer : Int32,
) -> Bool {
  let prefix = if path == "/" { "" } else { path }
  for node_path, node in self.nodes {
    if node_path == "/" {
      continue
    }
    let under = if prefix == "" {
      true
    } else {
      path_is_under(node_path, prefix)
    }
    if under && node.info.layer >= layer {
      return true
    }
  }
  false
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
    if path_is_under(node_path, path) && node.info.layer >= layer {
      self.set(node.with_info({ ..node.info, layer, }))
    }
  }
}

///|
/// opaque 语义：目录内容在本层被整体替换，抹掉本层没有重新写入的旧条目。
///
/// `.wh..wh..opq` 自身出现在该目录下，本层写过的条目一律保留；
/// 其余旧条目连同子树删除。判定看的是最近一次写入的层号，不是条目顺序，
/// 所以 `.wh..wh..opq` 写在子条目之后也不会误删本层内容。
///
/// 注意不能只删「直接子节点」：本层新写了 `sub/new`、而 `sub` 目录本身
/// 由更早的层创建时，只删旧子节点会把新内容一起带走。这里按「本层是否
/// 有后代」来判断，删掉整段没有后代属于本层的旧子树。
pub fn make_opaque(tree : FileTree, directory : String, layer : Int32) -> Unit {
  // 目录内所有后代，按深度从浅到深处理：父目录整段删掉后子路径已不存在
  let prefix = if directory == "/" { "" } else { directory }
  let descendents : Array[String] = []
  for node_path, _ in tree.nodes {
    if node_path == "/" || node_path == directory {
      continue
    }
    let under = if prefix == "" {
      true
    } else {
      path_is_under(node_path, prefix)
    }
    if under && path_depth(node_path) > path_depth(directory) {
      descendents.push(node_path)
    }
  }
  for node_path in descendents {
    // 本层写过的条目连同子树保留：它们就是 opaque 之后的新内容
    if tree.has_descendant_from(node_path, layer) {
      continue
    }
    remove_subtree(tree, node_path, layer) |> ignore
  }
  // 存活的那一支可能正好挂在被删节点下面，这里补挂一层
  for node_path in descendents {
    if tree.get(node_path) is Some(node) {
      for child in node.children {
        tree.relink_parent(child.path)
      }
    }
  }
}

///|
/// whiteout 语义：删除同目录下 `path` 的旧内容。
///
/// 只删来层早于本层的条目——同层重新写回的条目来层等于本层，必须保留。
/// `tar` 里 `.wh.<name>` 排在写回条目之前还是之后，效果都该一样。
///
/// 本层重写了这个条目时，它算「这一层重新建立的完整子树」：目录被重建后
/// 旧层塞进去的后代不该复活，所以连同旧后代一起清掉。
fn remove_prior_entry(tree : FileTree, path : String, layer : Int32) -> Unit {
  let rewritten = match tree.get(path) {
    Some(node) => node.info.layer >= layer
    None => false
  }
  if !rewritten {
    remove_subtree(tree, path, layer) |> ignore
    return
  }
  // 被本层重写的目录：先摘下旧后代，再逐个彻底删掉（含其子树）
  let stale = []
  for node_path in tree.collect_subtree(path) {
    if node_path != path &&
      tree.get(node_path) is Some(node) &&
      node.info.layer < layer {
      stale.push(node_path)
    }
  }
  for node_path in stale {
    remove_subtree(tree, node_path, layer) |> ignore
  }
}

///|
/// 按压缩方式解压一层的数据。`algorithm` 取 `"none"` / `"gzip"` / `"zstd"`。
pub async fn decompress_layer(
  data : BytesView,
  algorithm : String,
) -> Bytes raise DecompressError {
  match algorithm {
    "" | "none" => data.to_owned()
    "gzip" => gzip_decompress(data)
    "zstd" => zstd_decompress(data)
    _ => raise Unsupported(algorithm)
  }
}

///|
/// 按压缩方式解压一层，把结果写进 `sink`，不攒成一块。
///
/// `docker save` 这条链路要的正是这个形态：层解出来是几十上百 MB 的 tar，
/// 攒成 `Bytes` 再打包，峰值内存等于镜像解压后的体积。
///
/// zstd 这一支目前仍是「整段解压再写出」——上游解码器只给了
/// `BytesView -> Bytes` 的接口。它的输出上限写在 `zstd_max_output` 里，
/// 不会像 gzip 那样无限膨胀；等解码器公开流式入口再换成真流式。
pub async fn decompress_layer_to(
  data : BytesView,
  algorithm : String,
  sink : &@io.Writer,
) -> Unit raise DecompressError {
  match algorithm {
    "" | "none" => write_or_die(sink, data)
    "gzip" => gzip_decompress_to(data, sink)
    "zstd" => write_or_die(sink, zstd_decompress(data))
    _ => raise Unsupported(algorithm)
  }
}

///|
/// 写 `sink`，把写盘的错误折成解压错误的 `Io` 一支。
///
/// 解压产出往哪儿写是调用方决定的（文件、缓冲区、另一个流），
/// 写失败不该被解压器当成「压缩流坏了」，所以文案要区分开。
async fn write_or_die(
  sink : &@io.Writer,
  data : BytesView,
) -> Unit raise DecompressError {
  sink.write(data) catch {
    err => raise Write(err.to_string())
  }
}

///|
/// 解压并按 media type 推断压缩方式后应用到树上。
pub async fn apply_layer_with_media_type(
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
