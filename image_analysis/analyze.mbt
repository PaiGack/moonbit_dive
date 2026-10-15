///|
/// 逐层扫 tar 的账本：镜像里被 whiteout 删掉的内容已经不在树上，
/// 但它们在镜像里真实占着空间，所以必须逐层过一遍 tar 才能算清浪费。
///
/// 记录写在 `Ledger` 里，`tree` 只负责提供 P2 的层叠语义
/// （whiteout、opaque、覆盖、目录补建），调用方传进来的树会被推进到最后一层。
priv struct Ledger {
  analysis : Analysis
  /// 当前树上的路径 -> 字节数（目录与链接记 0）
  mut on_tree : Map[String, Int32]
  /// 每个路径在每层的版本字节数（按层序 append，0 表示该层删掉它）
  versions : Map[String, Array[Int32]]
}

///|
fn Ledger::new() -> Ledger {
  {
    analysis: {
      layers: 0,
      sizes: Map([]),
      usages: [],
      final_file_bytes: 0,
      final_paths: 0,
      overwritten_wasted: 0,
      deleted_wasted: 0,
      versions: None,
    },
    on_tree: Map([]),
    versions: Map([]),
  }
}

///|
/// 扫一遍整棵树的路径 -> 字节数。
fn snapshot_paths(tree : @layer_tree.FileTree) -> Map[String, Int32] {
  let paths : Map[String, Int32] = Map([])
  for path in tree.paths() {
    let size = match tree.get(path) {
      Some(node) => if node.is_file() { node.size } else { 0 }
      None => 0
    }
    paths.set(path, size)
  }
  paths
}

///|
/// 分析一串已解压的层，得到体积账。
///
/// `tree` 会被推进到最后一层；返回的 `Analysis` 是纯统计结果，
/// 不依赖 `tree` 之后的形态。`media_types` 缺省按未压缩处理。
pub fn analyze_layers(
  tree : @layer_tree.FileTree,
  layers : Array[BytesView],
  media_types~ : Array[String] = [],
) -> Analysis raise @layer_tree.LayerError {
  analyze_decompressed(
    tree,
    @layer_tree.decompress_layers(layers, media_types~),
  )
}

///|
/// 从已解压的层记账：与 `analyze_layers` 同一套口径，只是不再解压。
///
/// 拆出来是给「一次解压、两条链路共用」用的（issue #52）：
/// `browse_decompressed` 出逐层快照，这里出跨层统计，两边的输入是同一批 tar 字节。
pub fn analyze_decompressed(
  tree : @layer_tree.FileTree,
  decompressed : @layer_tree.DecompressedLayers,
) -> Analysis raise @layer_tree.LayerError {
  let ledger = Ledger::new()
  for index, raw in decompressed.raws {
    analyze_layer(tree, raw, index, ledger)
  }
  ledger.finish(tree, decompressed.raws.length())
}

///|
/// 收尾：把最终树上的占用写进结果。
fn Ledger::finish(
  self : Ledger,
  tree : @layer_tree.FileTree,
  layers : Int32,
) -> Analysis {
  self.analysis.layers = layers
  self.analysis.final_paths = tree.size()
  let mut total = 0
  for _, size in self.on_tree {
    total = total + size
  }
  self.analysis.final_file_bytes = total
  self.analysis.versions = Some({ versions: self.versions, })
  self.analysis
}

///|
/// 分析一层：先拿到「这一层会怎样」的清单，再落树，最后记账。
///
/// 分两步是因为落树之后旧值就没了，被覆盖 / 被删除的旧字节必须提前读出来。
fn analyze_layer(
  tree : @layer_tree.FileTree,
  raw : BytesView,
  layer : Int32,
  ledger : Ledger,
) -> Unit raise @layer_tree.LayerError {
  let plan = scan_layer(raw) catch { err => raise @layer_tree.Tar(err) }
  let before = snapshot_paths(tree)
  let usage = LayerUsage::new(layer)
  // 写入账：新增还是覆盖，覆盖掉的旧内容算浪费
  for entry in plan.entries {
    match before.get(entry.path) {
      None => usage.added_paths = usage.added_paths + 1
      Some(old) => {
        usage.overwritten_paths = usage.overwritten_paths + 1
        charge(ledger, entry.path, old)
        usage.wasted_bytes = usage.wasted_bytes + old
      }
    }
    usage.written_bytes = usage.written_bytes + entry.size
  }
  // 显式 whiteout：整棵子树全额算浪费
  for path in plan.deleted {
    for doomed in expand_subtree(before, path) {
      usage.deleted_paths = usage.deleted_paths + 1
      let old = old_bytes(before, doomed)
      charge_deleted(ledger, doomed, old)
      usage.wasted_bytes = usage.wasted_bytes + old
    }
  }
  // opaque：抹掉的旧内容单独一栏，它既不是被覆盖也不是显式 whiteout
  for directory in plan.erased {
    for doomed in directory_entries(before, directory) {
      let old = old_bytes(before, doomed)
      charge_deleted(ledger, doomed, old)
      usage.erased_bytes = usage.erased_bytes + old
    }
  }
  @layer_tree.apply_layer(tree, raw, layer) catch {
    err => raise @layer_tree.Tar(err)
  }
  sync_sizes(tree, ledger, layer)
  record_versions(ledger, plan)
  ledger.analysis.usages.push(usage)
}

///|
/// 某个路径删除前的字节数。
fn old_bytes(before : Map[String, Int32], path : String) -> Int32 {
  match before.get(path) {
    Some(size) => size
    None => 0
  }
}

///|
/// 记一笔浪费到路径账上，同时累加总数。
fn charge(ledger : Ledger, path : String, bytes : Int32) -> Unit {
  if bytes <= 0 {
    return
  }
  ledger.analysis.overwritten_wasted = ledger.analysis.overwritten_wasted +
    bytes
  let size = ledger.entry_for(path)
  size.wasted_bytes = size.wasted_bytes + bytes
}

///|
/// 记一笔「被删掉」的浪费。
fn charge_deleted(ledger : Ledger, path : String, bytes : Int32) -> Unit {
  if bytes <= 0 {
    return
  }
  ledger.analysis.deleted_wasted = ledger.analysis.deleted_wasted + bytes
  let size = ledger.entry_for(path)
  size.wasted_bytes = size.wasted_bytes + bytes
}

///|
/// 取路径账，没有就建一条。
fn Ledger::entry_for(self : Ledger, path : String) -> PathSize {
  match self.analysis.sizes.get(path) {
    Some(size) => size
    None => {
      let size = PathSize::new(path)
      self.analysis.sizes.set(path, size)
      size
    }
  }
}

///|
/// 把树上的现状同步进路径账：大小、写入层、是否已被删除。
///
/// 只有「本层写过、且现在在树上」的路径才更新 `size` / `current_layer`，
/// 否则会把上一层的旧值错记成本层写的。
fn sync_sizes(
  tree : @layer_tree.FileTree,
  ledger : Ledger,
  layer : Int32,
) -> Unit {
  let now = snapshot_paths(tree)
  for path in tree.paths() {
    let node = match tree.get(path) {
      Some(node) => node
      None => continue
    }
    if !node.is_file() || node.layer != layer {
      continue
    }
    let size = ledger.entry_for(path)
    size.size = match now.get(path) {
      Some(bytes) => bytes
      None => 0
    }
    size.writes = size.writes + 1
    size.deleted = false
    size.current_layer = Some(layer)
  }
  // 本层之后，之前记在树上、现在不在的路径就是被删了
  for path, _ in ledger.on_tree {
    if now.contains(path) {
      continue
    }
    let size = ledger.entry_for(path)
    size.size = 0
    size.deleted = true
    size.current_layer = None
  }
  ledger.on_tree = now
}

///|
/// 展开一个被删除路径及其子树。
fn expand_subtree(before : Map[String, Int32], path : String) -> Array[String] {
  // path_is_under 把等于自身也算作「在下面」，所以这里不额外补 path
  let result = []
  for other, _ in before {
    if @layer_tree.path_is_under(other, path) {
      result.push(other)
    }
  }
  result.sort_by(@layer_tree.path_order)
  result
}

///|
/// 某目录的直接子条目（opaque 抹掉的范围只到该目录的第一层，
/// 子树随其被删的根一起消失）。
fn directory_entries(
  before : Map[String, Int32],
  directory : String,
) -> Array[String] {
  let result = []
  for path, _ in before {
    if @layer_tree.parent_path(path) == directory {
      result.push(path)
    }
  }
  result.sort_by(@layer_tree.path_order)
  result
}

///|
/// 把这一层的写入记进版本表，供 efficiency 逐路径聚合。
///
/// 只记「有实质大小」的条目：目录、0 字节点、链接都不参与分数，
/// 但被删除的路径要记一笔 0——它会参与 min 的计算。
fn record_versions(ledger : Ledger, plan : LayerPlan) -> Unit {
  for entry in plan.entries {
    if entry.size <= 0 {
      continue
    }
    push_version(ledger, entry.path, entry.size)
  }
  for path in plan.deleted {
    push_version(ledger, path, 0)
  }
  for directory in plan.erased {
    push_version(ledger, directory, 0)
  }
}

///|
/// 往某路径的版本序列里追加一个版本。
fn push_version(ledger : Ledger, path : String, size : Int32) -> Unit {
  let bucket = match ledger.versions.get(path) {
    Some(bucket) => bucket
    None => {
      let bucket : Array[Int32] = []
      ledger.versions.set(path, bucket)
      bucket
    }
  }
  bucket.push(size)
}

///|
/// 树上文件的字节数：路径 -> 大小。目录与链接不进表。
pub fn file_sizes(tree : @layer_tree.FileTree) -> Map[String, Int32] {
  let result : Map[String, Int32] = Map([])
  for path in tree.paths() {
    match tree.get(path) {
      Some(node) =>
        if node.is_file() && node.size > 0 {
          result.set(path, node.size)
        }
      None => ()
    }
  }
  result
}
