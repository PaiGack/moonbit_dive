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
