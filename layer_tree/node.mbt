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
/// 文件树节点。路径用树内绝对路径（`/usr/bin/sh`），根节点固定为 `/`。
pub(all) struct Node {
  path : String
  /// 被后层覆盖时原地改写
  mut kind : NodeKind
  /// 常规文件的数据长度；目录与链接为 0
  mut size : Int32
  /// 低 12 位权限（八进制字面量书写，如 `0o755`）
  mut mode : Int32
  /// 归属的层下标：当前内容由哪一层写入
  mut layer : Int32
  /// entry 里记录的修改时间（Unix 秒），缺省为 0
  mut mtime : Int32
  /// 子节点，按路径字典序保持稳定，便于渲染与快照
  mut children : Array[Node]
} derive(Debug)

///|
pub extend Node with @debug.Debug::{to_repr}

///|
pub impl Show for Node with fn to_string(self) {
  match self.kind {
    File => "\{self.path} (\{self.size} bytes)"
    Directory => "\{self.path}/"
    Symlink(target) => "\{self.path} -> \{target}"
    Hardlink(target) => "\{self.path} ==> \{target}"
  }
}

///|
pub extend Node with Show::{to_string, output}

///|
/// 新建一个节点，`children` 为空。
pub fn Node::new(
  path : String,
  kind : NodeKind,
  size~ : Int32 = 0,
  mode~ : Int32 = 0o644,
  layer~ : Int32 = 0,
  mtime~ : Int32 = 0,
) -> Node {
  { path, kind, size, mode, layer, mtime, children: [], }
}

///|
/// 节点是否是目录。
pub fn Node::is_dir(self : Node) -> Bool {
  self.kind is Directory
}

///|
/// 节点是否是常规文件（硬链接按文件对待）。
pub fn Node::is_file(self : Node) -> Bool {
  match self.kind {
    File | Hardlink(_) => true
    _ => false
  }
}

///|
/// 节点是否是链接（软或硬）。
pub fn Node::is_link(self : Node) -> Bool {
  match self.kind {
    Symlink(_) | Hardlink(_) => true
    _ => false
  }
}

///|
/// 链接目标；非链接返回 `None`。
pub fn Node::link_target(self : Node) -> String? {
  match self.kind {
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
pub fn Node::insert_child(self : Node, child : Node) -> Unit {
  let mut index = 0
  while index < self.children.length() &&
        path_order(self.children[index].path, child.path) < 0 {
    index = index + 1
  }
  self.children.insert(index, child)
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
/// 移除直接子节点，返回是否存在。
pub fn Node::remove_child(self : Node, path : String) -> Bool {
  let mut index = 0
  while index < self.children.length() {
    if self.children[index].path == path {
      self.children.remove(index) |> ignore
      return true
    }
    index = index + 1
  }
  false
}
