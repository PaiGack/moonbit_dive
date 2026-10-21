///|
/// 文件树节点类型。hardlink 是独立类型而不是「指向目标的引用」：
/// 它记录链接目标路径，内容随目标变化，符合 AUFS/overlayfs 的语义。
pub(all) enum NodeKind {
  File
  Directory
  Symlink(String)
  Hardlink(String)
} derive(Eq, Debug)

///|
pub extend NodeKind with Eq::{equal, not_equal}

///|
pub extend NodeKind with @debug.Debug::{to_repr}

///|
pub impl Show for NodeKind with fn to_string(self) {
  match self {
    File => "file"
    Directory => "dir"
    Symlink(_) => "symlink"
    Hardlink(_) => "hardlink"
  }
}

///|
pub extend NodeKind with Show::{to_string, output}

///|
/// 节点被覆盖的一次记录：某一层用某个类型、某个大小改写了这个路径。
///
/// `layer` 是产生这次写入的层下标（从 0 开始）；对软/硬链接不记录大小。
pub(all) struct LayerWrite {
  layer : Int32
  kind : NodeKind
  size : Int32
} derive(Eq, Debug)

///|
pub extend LayerWrite with Eq::{equal, not_equal}

///|
pub extend LayerWrite with @debug.Debug::{to_repr}

///|
pub impl Show for LayerWrite with fn to_string(self) {
  "L\{self.layer} \{self.kind} ({self.size} bytes)"
}

///|
pub extend LayerWrite with Show::{to_string, output}

///|
/// 节点的元数据：一次写入定下来的那一份，之后不再改。
///
/// 拆出来是为了让「覆写 = 换一份 info」只在一处发生（`Node::overwrite`）：
/// 节点本体不可变，快照才能按路径共享没动过的节点（issue #122 第 5 项）。
pub(all) struct NodeInfo {
  kind : NodeKind
  /// 常规文件的数据长度；目录与链接为 0
  size : Int32
  /// 低 12 位权限（八进制字面量书写，如 `0o755`）
  mode : Int32
  /// 属主 / 属组（tar 头里的 uid / gid）；目录补齐与链接按 0 记
  uid : Int32
  gid : Int32
  /// 归属的层下标：当前内容由哪一层写入
  layer : Int32
  /// entry 里记录的修改时间（Unix 秒），缺省为 0
  mtime : Int32
} derive(Eq, Debug)

///|
pub extend NodeInfo with Eq::{equal, not_equal}

///|
pub extend NodeInfo with @debug.Debug::{to_repr}

///|
/// 文件树节点。路径用树内绝对路径（`/usr/bin/sh`），根节点固定为 `/`。
///
/// **节点不可变**：一条 entry 落下来就是换一个新 `Node`（metadata 换一份
/// `NodeInfo`，`children` 换成新的数组），父目录也顺着换一遍。
/// 这不是洁癖，是 `snapshot` 能共享节点的前提——一份快照拿着的节点，
/// 后面任何一层都改不到它。
pub(all) struct Node {
  path : String
  info : NodeInfo
  /// 当前内容的指纹；`None` 表示这个节点还没做过内容比对
  digest : Digest?
  /// 写入流水，按层序排列（`scan_content` 填充）
  files : Array[NodeFile]
  /// 子节点，按路径字典序保持稳定，便于渲染与快照
  children : Array[Node]
} derive(Debug)

///|
pub extend Node with @debug.Debug::{to_repr}

///|
pub impl Show for Node with fn to_string(self) {
  match self.info.kind {
    File => "\{self.path} (\{self.info.size} bytes)"
    Directory => "\{self.path}/"
    Symlink(target) => "\{self.path} -> \{target}"
    Hardlink(target) => "\{self.path} ==> \{target}"
  }
}

///|
pub extend Node with Show::{to_string, output}

///|
/// 一个节点的内容指纹。
///
/// 逐层叠树时不比对内容（那要把每层的每个文件都读一遍），
/// 只在真要比两次快照时才按需算，因此这里允许为空。
pub(all) struct Digest {
  /// 这个节点的内容被改写过的次数（含第一次写入）
  changes : Int32
  /// 当前内容的 sha256 摘要，全小写 hex；没有内容（目录 / 链接）为 `None`
  hash : String?
} derive(Eq, Debug)

///|
pub extend Digest with Eq::{equal, not_equal}

///|
pub extend Digest with @debug.Debug::{to_repr}

///|
pub impl Show for Digest with fn to_string(self) {
  let hash = match self.hash {
    Some(hash) => hash
    None => "-"
  }
  "changes=\{self.changes} \{hash}"
}

///|
pub extend Digest with Show::{to_string, output}

///|
/// 一个节点的一次写入：在哪一层写的、多大、内容摘要是什么。
///
/// 同一层里同一路径被写了两次只留最后一份（与 `apply_layer` 的语义一致）；
/// 链接与目录也会有记录，摘要为 `None`。
pub(all) struct NodeFile {
  /// 写这份内容的层下标
  layer : Int32
  size : Int32
  /// 内容摘要；`None` 表示这条 entry 不带内容
  hash : String?
} derive(Eq, Debug)

///|
pub extend NodeFile with Eq::{equal, not_equal}

///|
pub extend NodeFile with @debug.Debug::{to_repr}

///|
pub impl Show for NodeFile with fn to_string(self) {
  match self.hash {
    Some(hash) => "L\{self.layer} \{self.size} bytes \{hash}"
    None => "L\{self.layer} \{self.size} bytes"
  }
}

///|
pub extend NodeFile with Show::{to_string, output}

///|
/// 新建一个节点，`children` 为空、没有摘要、没有写入流水。
pub fn Node::new(
  path : String,
  kind : NodeKind,
  size~ : Int32 = 0,
  mode~ : Int32 = 0o644,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  layer~ : Int32 = 0,
  mtime~ : Int32 = 0,
) -> Node {
  {
    path,
    info: { kind, size, mode, uid, gid, layer, mtime, },
    digest: None,
    files: [],
    children: [],
  }
}

///|
/// 换一份元数据，得到一个指向同一个 `children` 的新节点。
///
/// 摘要与写入流水跟着走：它们记的是「这个路径上发生过什么」，
/// 覆写不改这两本账，要清由 `scan_content` 负责。
pub fn Node::with_info(self : Node, info : NodeInfo) -> Node {
  { ..self, info, }
}

///|
/// 换一份 `children`，路径与元数据不动。
pub fn Node::with_children(self : Node, children : Array[Node]) -> Node {
  { ..self, children, }
}

///|
/// 一条 entry 落到这个节点上：元数据整份换新，`children` 原样保留
/// （覆写成目录时不该顺手丢掉还没挂回来的子节点）。
///
/// 落树时只走这一个入口，节点本体因此永远不变——
/// 「先快照、再叠层」不会把快照里的节点一起改掉。
pub fn Node::overwrite(
  self : Node,
  kind : NodeKind,
  size~ : Int32 = 0,
  mode~ : Int32 = 0o644,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  layer~ : Int32 = 0,
  mtime~ : Int32 = 0,
) -> Node {
  self.with_info({ kind, size, mode, uid, gid, layer, mtime, })
}

///|
/// 节点是否是目录。
pub fn Node::is_dir(self : Node) -> Bool {
  self.info.kind is Directory
}

///|
/// 节点是否是常规文件（硬链接按文件对待）。
pub fn Node::is_file(self : Node) -> Bool {
  match self.info.kind {
    File | Hardlink(_) => true
    _ => false
  }
}

///|
/// 节点是否是链接（软或硬）。
pub fn Node::is_link(self : Node) -> Bool {
  match self.info.kind {
    Symlink(_) | Hardlink(_) => true
    _ => false
  }
}

///|
/// 链接目标；非链接返回 `None`。
pub fn Node::link_target(self : Node) -> String? {
  match self.info.kind {
    Symlink(target) | Hardlink(target) => Some(target)
    _ => None
  }
}

///|
/// 按文件名顺序插入子节点，保持 `children` 稳定有序。
///
/// 同一目录下的子节点路径前缀相同，比较完整路径等于比较文件名；
/// 但不能用字符串默认的 `<`（它把 `/` 排在字母之后，结果不直观），
/// 因此统一走 `path_order`。
///
/// 返回一个新节点，原节点不动（见 `Node` 的注释：节点不可变）。
pub fn Node::insert_child(self : Node, child : Node) -> Node {
  let mut index = 0
  while index < self.children.length() &&
        path_order(self.children[index].path, child.path) < 0 {
    index = index + 1
  }
  let children = self.children.copy()
  children.insert(index, child)
  self.with_children(children)
}

///|
/// 直接子节点里按路径查找。
pub fn Node::find_child(self : Node, path : String) -> Node? {
  for child in self.children {
    if child.path == path {
      return Some(child)
    }
  }
  None
}

///|
/// 移除直接子节点，返回新节点与「是否存在」。
///
/// 没这个子节点时原样返回 `(self, false)`，不白拷一份数组。
pub fn Node::without_child(self : Node, path : String) -> (Node, Bool) {
  match self.index_of_child(path) {
    Some(index) => {
      let children = self.children.copy()
      children.remove(index) |> ignore
      (self.with_children(children), true)
    }
    None => (self, false)
  }
}

///|
/// 直接子节点的下标；没有给 `None`。
fn Node::index_of_child(self : Node, path : String) -> Int32? {
  let mut index = 0
  while index < self.children.length() {
    if self.children[index].path == path {
      return Some(index)
    }
    index = index + 1
  }
  None
}
