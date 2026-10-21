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
/// 把 `node` 换成新的版本。
///
/// 节点不可变（见 `Node` 的注释），所以「改一个节点」只有这一个写法：
/// 换掉 `nodes` 里的那一份。已经发出去的旧 `Node`（快照、视图）不受影响。
pub fn FileTree::set(self : FileTree, node : Node) -> Unit {
  self.nodes.set(node.path, node)
}

///|
/// 取某个路径的父目录节点；根、未挂上的路径返回 `None`。
pub fn FileTree::parent_of(self : FileTree, path : String) -> Node? {
  if path == "/" {
    return None
  }
  self.nodes.get(parent_path(path))
}

///|
/// 把 `path` 的父目录换成新版本，并把这次改动一路换到根。
///
/// 父目录的 `children` 变了就得换掉父目录那一份：`nodes` 里的节点是
/// 视图与快照共用的引用，原地改它等于把历史一起改了。
/// 换完之后，父目录在祖父目录的 `children` 里也是旧的一份了，
/// 所以要顺着父链换上去——一路到根。
///
/// `update` 拿到上一层的目录、返回「换过 `children` 的目录」；某一层
/// 已经不在 `nodes` 里（子树删除）时直接停，再往上没有可换的东西。
fn FileTree::refresh_parent(
  self : FileTree,
  path : String,
  update : (Node) -> Node,
) -> Unit {
  if path == "/" {
    return
  }
  let parent_path_value = parent_path(path)
  let parent = match self.nodes.get(parent_path_value) {
    Some(parent) => update(parent)
    None => return
  }
  self.set(parent)
  // 祖父目录里那一份还是「换之前的父目录」，得跟着换：
  // 先摘掉旧的那条再插入，否则原位追加会留下两个同名子节点
  self.refresh_parent(parent_path_value, fn(grand) {
    grand.without_child(parent_path_value).0.insert_child(parent)
  })
}

///|
/// `path` 重新挂进它父目录（`path` 必须已经在 `nodes` 里）。
///
/// 同一个路径可能被挂两次（`ensure_parents` 补建、`promote_orphans` 挂孤儿、
/// 覆写后重挂），所以是「先摘掉旧的、再按序插入」，不是直接追加：
/// 父目录里留着同名旧条目的话，同一层会被渲染两遍。
fn FileTree::relink_parent(self : FileTree, path : String) -> Unit {
  let node = self.require_node(path)
  self.refresh_parent(path, fn(parent) {
    parent.without_child(path).0.insert_child(node)
  })
}

///|
/// 从父目录里摘掉 `path`（`path` 自己已经从 `nodes` 里删掉）。
fn FileTree::detach_parent(self : FileTree, path : String) -> Unit {
  self.refresh_parent(path, fn(parent) { parent.without_child(path).0 })
}

///|
/// 取节点，缺失时就地炸：调用点都是「刚刚确认过存在」的内部路径。
fn FileTree::require_node(self : FileTree, path : String) -> Node {
  match self.nodes.get(path) {
    Some(node) => node
    None => abort("node missing from tree: \{path}")
  }
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
///
/// 节点不可变，根被换掉时 `nodes["/"]` 指向新的那一份，字段 `root` 跟不上，
/// 所以这里统一从 `nodes` 取：`root().children` 必须是「这一刻的树」。
pub fn FileTree::root(self : FileTree) -> Node {
  match self.nodes.get("/") {
    Some(root) => root
    None => self.root
  }
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
