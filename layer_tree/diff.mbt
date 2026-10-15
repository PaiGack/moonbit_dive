///|
/// 相邻两层之间的差异。
///
/// `removed` 来自 whiteout 推导（或该路径在新层里消失），不是简单集合差：
/// 「先删后加同名文件」会同时出现在 `removed` 与 `added` 里，如实反映 OCI 的层语义。
pub(all) struct Diff {
  /// 上一层的层号；`-1` 表示与空树比较（第一层）
  base : Int32
  layer : Int32
  added : Array[String]
  modified : Array[String]
  removed : Array[String]
} derive(Eq, Debug)

///|
pub extend Diff with Eq::{equal, not_equal}

///|
pub extend Diff with @debug.Debug::{to_repr}

///|
pub impl Show for Diff with fn to_string(self) {
  "\{self.section_name()}: +\{self.added.length()} ~\{self.modified.length()} -\{self.removed.length()}"
}

///|
pub extend Diff with Show::{to_string, output}

///|
/// 区块标题：与空树比较时叫 `L0`，否则是 `Lbase -> Llayer`。
pub fn Diff::section_name(self : Diff) -> String {
  if self.base < 0 {
    "L\{self.layer}"
  } else {
    "L\{self.base} -> L\{self.layer}"
  }
}

///|
/// 差异是否为空。
pub fn Diff::is_empty(self : Diff) -> Bool {
  self.added.is_empty() && self.modified.is_empty() && self.removed.is_empty()
}

///|
/// 三组路径的合计条数。
pub fn Diff::total(self : Diff) -> Int32 {
  self.added.length() + self.modified.length() + self.removed.length()
}

///|
/// 逐层应用并记录每层产生的 diff。
///
/// 返回的 `Array[Diff]` 与 `layers` 一一对应：第 0 层是与空树比，
/// 第 n 层是与第 n-1 层比。`apply_layers_with_diffs` 的返回结构。
pub struct LayerDiffResult {
  tree : FileTree
  diffs : Array[Diff]
} derive(Debug)

///|
pub extend LayerDiffResult with @debug.Debug::{to_repr}

///|
/// 依次应用多层 tar，同时收集层间 diff。
///
/// `layers` 里每个元素是一层的原始数据；`media_types` 缺省按未压缩处理。
pub fn apply_layers_with_diffs(
  layers : Array[BytesView],
  media_types~ : Array[String] = [],
) -> LayerDiffResult raise LayerError {
  let tree = FileTree::new()
  let diffs = []
  for index, stream in layers {
    let media_type = if index < media_types.length() {
      media_types[index]
    } else {
      "none"
    }
    let algorithm = compression_of(media_type)
    let raw = decompress_layer(stream, algorithm) catch {
      err => raise Decompress(err)
    }
    // whiteout 只在树的增量上可见，因此逐层「先复制、再应用、再比对」
    let before = tree.snapshot()
    apply_layer(tree, raw, index) catch {
      err => raise Tar(err)
    }
    diffs.push(diff_snapshots(before, tree.snapshot(), index - 1, index))
  }
  { tree, diffs, }
}

///|
/// 与空树比较，算出第 `layer` 层整体的差异。
pub fn diff_against_empty(tree : FileTree, layer : Int32) -> Diff {
  let added = []
  let modified = []
  for path in tree.paths() {
    added.push(path)
    modified.push(path)
  }
  { base: -1, layer, added, modified, removed: [], }
}

///|
/// 比较两棵树，得到 `layer` 层相对上一层的差异。
///
/// 规则：
/// - 新树有、旧树没有 -> added
/// - 两棵树都有但大小或类型变了 -> modified
/// - 旧树有、新树没有 -> removed（这正是 whiteout 的结果）
pub fn diff_snapshots(
  before : FileTree,
  after : FileTree,
  base : Int32,
  layer : Int32,
) -> Diff {
  let added = []
  let modified = []
  let removed = []
  for path, node in after.nodes {
    if path == "/" {
      continue
    }
    match before.nodes.get(path) {
      None => added.push(path)
      Some(previous) =>
        if previous.size != node.size || previous.kind != node.kind {
          modified.push(path)
        }
    }
  }
  for path, _ in before.nodes {
    if path != "/" && !after.nodes.contains(path) {
      removed.push(path)
    }
  }
  added.sort_by(path_order)
  modified.sort_by(path_order)
  removed.sort_by(path_order)
  { base, layer, added, modified, removed, }
}

///|
/// 把当前树复制一份，用于逐层比对。
///
/// 每个节点都重建（类型、大小、层号一并拷贝），因此快照与后续层的写入互相隔离；
/// 只拷节点不拷历史，`snapshot` 的用途是拿「某一时刻的形状」去比大小与类型。
pub fn FileTree::snapshot(self : FileTree) -> FileTree {
  let copy = FileTree::new()
  for path, node in self.nodes {
    if path == "/" {
      continue
    }
    let cloned = Node::new(
      node.path,
      node.kind,
      size=node.size,
      mode=node.mode,
      layer=node.layer,
      mtime=node.mtime,
    )
    copy.nodes.set(path, cloned)
    copy.attach(cloned)
  }
  copy.layers = self.layers
  copy
}

///|
/// 聚合比较：把 `base` 到 `layer` 这一段区间的改动**累积**成一份 diff。
///
/// 为什么不是「拿两棵树做一次 `diff_snapshots`」：`diff_snapshots` 只比大小与类型，
/// 「第 0 层写过、第 2 层又改回原样」的路径在两个端点上字节一模一样，
/// 会被判成没动过——而看树的人问的是「这段区间里动过谁」。原版 dive 的聚合档
/// 就是这个口径（逐层叠加时把 diff 往父目录合并），所以这里按区间**累积**：
///
/// 1. 取 `per_layer` 里 `base + 1 .. layer` 这些层「碰过」的全部路径
/// 2. 按 `before`（`base` 层的树）/ `after`（`layer` 层的树）给它们归类：
///    只在 `after` -> `added`，两头都在 -> `modified`，只在 `before` -> `removed`
/// 3. 区间内碰过、最后又两头都不在的路径直接丢掉——视图画的是 `after` 的树，
///    一条既不在起点也不在终点的路径没有行可以落
/// 4. 没被直接碰过、但**子树里有改动**的目录并入 `modified`：
///    dive 的 `deriveDiffType` 就是「子节点的 diff 往父目录合并」，
///    否则「子目录里的文件改了」在父目录那一行看不出来
///
/// `before` 传空树时（`base < 0`）等价于「第 0 层相对空树」，与 `diff_against_empty`
/// 同口径。`per_layer[i]` 是第 `i` 层的逐层 diff（即 `browse_decompressed`
/// 已经算过的那批），因此聚合档不必回到 tar 重新叠层。
pub fn diff_aggregate(
  before : FileTree,
  after : FileTree,
  per_layer : Array[Diff],
  base : Int32,
  layer : Int32,
) -> Diff {
  // 1. 区间内被碰过的路径
  let touched : Map[String, Unit] = Map([])
  let mut index = if base + 1 < 0 { 0 } else { base + 1 }
  while index <= layer && index < per_layer.length() {
    let diff = per_layer[index]
    for path in diff.added {
      touched.set(path, ())
    }
    for path in diff.modified {
      touched.set(path, ())
    }
    for path in diff.removed {
      touched.set(path, ())
    }
    index = index + 1
  }
  // 2. 按两端的存在性归类
  let added = []
  let modified = []
  let removed = []
  let status : Map[String, Int32] = Map([])
  for path, _ in touched {
    let in_before = before.nodes.contains(path)
    let in_after = after.nodes.contains(path)
    if in_after && !in_before {
      added.push(path)
      status.set(path, aggregate_added)
    } else if in_after && in_before {
      modified.push(path)
      status.set(path, aggregate_modified)
    } else if !in_after && in_before {
      removed.push(path)
      status.set(path, aggregate_removed)
    }
  }
  // 3. 父目录合并：没被直接碰过、但子树里有改动的目录算 modified
  merge_parent_diffs(after, status, modified)
  added.sort_by(path_order)
  modified.sort_by(path_order)
  removed.sort_by(path_order)
  { base, layer, added, modified, removed, }
}

///|
/// 聚合归类用的三个哨兵值（`Map` 的值存 `Int32`，比存枚举少一层装箱）。
let aggregate_added : Int32 = 0

///|
let aggregate_modified : Int32 = 1

///|
let aggregate_removed : Int32 = 2

///|
/// 把子树的改动往父目录合并：目录自己没被碰过、但子节点有状态时，目录算 `modified`。
///
/// 自深到浅推进：深层的目录先定型，它的父目录才看得到合并后的结果。
/// 已经被直接碰过的目录不覆盖——它的类别由「两端存不存在」决定，比合并更准。
fn merge_parent_diffs(
  after : FileTree,
  status : Map[String, Int32],
  modified : Array[String],
) -> Unit {
  let dirs = []
  for path, node in after.nodes {
    if path != "/" && node.is_dir() {
      dirs.push(path)
    }
  }
  dirs.sort_by(fn(left, right) { path_depth(right) - path_depth(left) })
  for dir in dirs {
    if status.contains(dir) {
      continue
    }
    let parent = match after.nodes.get(dir) {
      Some(node) => node
      None => continue
    }
    let mut hit = false
    for child in parent.children {
      if status.contains(child.path) {
        hit = true
      }
    }
    if hit {
      status.set(dir, aggregate_modified)
      modified.push(dir)
    }
  }
}
