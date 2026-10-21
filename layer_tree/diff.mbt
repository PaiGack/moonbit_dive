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
pub async fn apply_layers_with_diffs(
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
/// 判等口径对齐原版 dive 的 `FileInfo::Compare`：`(kind, mode, uid, gid)` 全等
/// 才算 `Unmodified`，另加 `size` 与内容指纹两条。任一项不同即 modified：
///
/// - kind / mode / 属主 / size 变了 -> modified
/// - 两侧都带内容指纹（`Node::digest`，来自 `scan_content` 或 `browse_*`）
///   且指纹不同 -> modified，这样「同大小、同 mode、同 mtime，内容不同」也认得出
/// - 两侧都不带指纹时只看元数据与 size，不会外加一次全量哈希（issue #71 的取舍）
///
/// **mtime 不参与**：原版不看它，`COPY` 刷新时间戳不该算改动。
/// `size` 参与是因为同 kind 下它变了必然意味着内容变了，与对齐后的口径不冲突。
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
      Some(previous) => if node_differs(previous, node) { modified.push(path) }
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
/// 一个节点相对上一版本算不算改过：元数据 + size + 内容指纹。
///
/// 是 `diff_snapshots` 判 `modified` 的唯一出口，改动只需改这一处。
fn node_differs(previous : Node, current : Node) -> Bool {
  // 元数据逐项比。注意这里先各自算成具名变量再合：
  // 多行 `||` 链直接写在 `if` 条件里时，实测后半段不参与短路
  // （`a ||\n b ||\n c` 只按第一项判），所以不省这两步
  let kind_differs = previous.kind != current.kind
  let mode_differs = previous.mode != current.mode
  let uid_differs = previous.uid != current.uid
  let gid_differs = previous.gid != current.gid
  let size_differs = previous.size != current.size
  if kind_differs || mode_differs || uid_differs || gid_differs || size_differs {
    return true
  }
  // 内容指纹：两边都扫过内容时才比得了。只有一边有（比如只给一侧跑过
  // `scan_content`）就当内容没变，交给元数据与 size 去判——否则每一次
  // 「先快照、再叠层、再快照」的调用都会因为 `before` 没摘要而全判 modified
  match (previous.digest, current.digest) {
    (Some(left), Some(right)) => left.hash != right.hash
    _ => false
  }
}

///|
/// 把当前树复制一份，用于逐层比对。
///
/// 每个节点都重建（类型、大小、权限、属主、内容指纹一并拷贝），因此快照与后续层的
/// 写入互相隔离；只拷节点不拷历史，`snapshot` 的用途是拿「某一时刻的形状」去比。
///
/// 为什么不按路径共享节点（issue #122 的第 5 项试过）：`FileTree` 对外暴露
/// `get` / `root().children`，拿到的是 `Node` 引用，而 `apply_layer` 覆写路径时
/// 只改字段、不换新节点（要保住 `parent.children` 里那一份）。一旦共享，
/// 「先快照、再叠层」就会把快照里的节点一起改掉，`diff_snapshots` 全判没动过。
/// 真要共享，得先把 P2 的节点全部改成「覆写即换新节点」，那是另一个量级的改动。
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
      uid=node.uid,
      gid=node.gid,
      layer=node.layer,
      mtime=node.mtime,
    )
    cloned.digest = node.digest
    cloned.files = node.files.copy()
    copy.nodes.set(path, cloned)
    copy.attach(cloned)
  }
  copy.layers = self.layers
  copy
}

///|
/// 聚合比较：把 `base` 到 `layer` 这一段区间的改动**累积**成一份 diff。
///
/// 为什么不是「拿两棵树做一次 `diff_snapshots`」：`diff_snapshots` 比的是两个端点，
/// 「第 0 层写过、第 2 层又改成别的、第 3 层再改回来」的路径在两个端点上一样，
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
    match (before.nodes.get(path), after.nodes.get(path)) {
      (None, Some(_)) => {
        added.push(path)
        status.set(path, aggregate_added)
      }
      (Some(_), Some(_)) => {
        // 区间内碰过就算动过，不再比一次两端：聚合档回答的是「这段区间里
        // 这条路径动没动」，回看内容反而会把「先改后改回来」的路径漏掉
        modified.push(path)
        status.set(path, aggregate_modified)
      }
      (Some(_), None) => {
        removed.push(path)
        status.set(path, aggregate_removed)
      }
      (None, None) => ()
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
