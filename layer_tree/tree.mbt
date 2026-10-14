///|
/// 层叠文件树。根节点固定为 `/`，随后续层逐层演进。
///
/// 结构上的约定：
/// - `orphans` 记录还没有父目录的节点（tar 里目录 entry 可能后于文件出现，
///   甚至整层都不给目录 entry），拿到父节点后再挂上，避免为每条路径造中间节点
/// - `history` 是一条 append-only 的覆盖日志，逐行记录「哪个层改了哪个路径」
pub(all) struct FileTree {
  root : Node
  /// 当前生效的层数
  mut layers : Int32
  nodes : Map[String, Node]
  /// 尚未挂到父目录下的节点，key 为其父路径
  mut orphans : Map[String, Array[Node]]
  /// append-only 的覆盖日志，每行 `<路径> <层号> <类型> (<大小> bytes)`
  mut history : String
  /// layer index -> 变更路径数 / 变更字节数 / 删除路径数
  mut layer_stats : Array[LayerStat]
} derive(Debug)

///|
pub extend FileTree with @debug.Debug::{to_repr}

///|
pub impl Show for FileTree with fn to_string(self) {
  "FileTree(layers=\{self.layers}, nodes=\{self.size()})"
}

///|
pub extend FileTree with Show::{to_string, output}

///|
/// 单层的统计：变更与被删除的规模。给 P3 的 efficiency score 用。
pub(all) struct LayerStat {
  layer : Int32
  mut changed_paths : Int32
  mut changed_bytes : Int32
  /// 被 whiteout 掉的路径数（含子树）
  mut deleted_paths : Int32
} derive(Eq, Debug)

///|
pub extend LayerStat with Eq::{equal, not_equal}

///|
pub extend LayerStat with @debug.Debug::{to_repr}

///|
pub impl Show for LayerStat with fn to_string(self) {
  "L\{self.layer}: \{self.changed_paths} changed (\{self.changed_bytes} bytes), \{self.deleted_paths} deleted"
}

///|
pub extend LayerStat with Show::{to_string, output}

///|
/// 新建一棵只有根节点的树。
pub fn FileTree::new() -> FileTree {
  let root = Node::new("/", NodeKind::Directory, mode=0o755)
  {
    root,
    layers: 0,
    nodes: { "/": root },
    orphans: {},
    history: "",
    layer_stats: [],
  }
}

///|
/// 追加一条覆盖记录。
///
/// 历史是一条 append-only 的日志行序列，格式为 `<路径> <层号> <类型> (<大小> bytes)`，
/// 写入顺序即 layer 顺序。查询时按路径过滤，因此天然保留「谁改过、改成什么」。
fn FileTree::record(self : FileTree, path : String, entry : LayerWrite) -> Unit {
  self.history = self.history + path + " " + entry.to_string() + "\n"
}

///|
/// 某路径的覆盖历史，最早写入的层在前；从未被写过的路径返回空串。
pub fn FileTree::history_of(self : FileTree, path : String) -> String {
  let mut lines = ""
  for line in self.history.split("\n") {
    if line.is_empty() {
      continue
    }
    let text = line.to_owned()
    let separator = match text.find(" ") {
      Some(index) => index
      None => -1
    }
    if separator <= 0 {
      continue
    }
    if text[:separator] == path {
      lines = lines + text[separator + 1:].to_owned() + "\n"
    }
  }
  lines
}

///|
/// 取路径对应的节点。
pub fn FileTree::get(self : FileTree, path : String) -> Node? {
  self.nodes.get(path)
}

///|
/// 取路径对应的节点，缺失时报错。
pub fn FileTree::require(self : FileTree, path : String) -> Node raise {
  match self.nodes.get(path) {
    Some(node) => node
    None => fail("node not found in tree: \{path}")
  }
}

///|
/// 节点总数（不含根）。
pub fn FileTree::size(self : FileTree) -> Int32 {
  self.nodes.length() - 1
}

///|
/// 根节点。
pub fn FileTree::root(self : FileTree) -> Node {
  self.root
}

///|
/// 某层的统计。
pub fn FileTree::stat(self : FileTree, layer : Int32) -> LayerStat? {
  if layer >= 0 && layer < self.layer_stats.length() {
    Some(self.layer_stats[layer])
  } else {
    None
  }
}

///|
/// 所有层的统计，按层序。
pub fn FileTree::layer_stats(self : FileTree) -> Array[LayerStat] {
  self.layer_stats.copy()
}

///|
/// 树内所有路径，按树状顺序（父目录先于子节点）。
pub fn FileTree::paths(self : FileTree) -> Array[String] {
  let result = []
  for path, _ in self.nodes {
    if path != "/" {
      result.push(path)
    }
  }
  result.sort_by(path_order)
  result
}
