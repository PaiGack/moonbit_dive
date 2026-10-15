///|
/// 交互式看树的「视图状态」：把 `layer_tree` 的树拍平成一列可上下走的行，
/// 再叠上展开/折叠与光标。
///
/// 为什么拍平：TUI 的按键（↑↓）走的是「可见行的下一行」，而树本身是嵌套的；
/// 每帧现算一遍可见行既慢又难保证光标位置稳定。这里把「哪些行现在可见」
/// 一次性算出来，键盘只在这个数组上移光标，画面按游标重画。
///
/// 不持有 `FileTree` 本体：视图只认 `(path, depth, kind, size, layer)` 这些
/// 渲染需要的字段，换数据源（逐层视图 / 效率视图）不用改键盘逻辑。
pub(all) struct Row {
  /// 树内绝对路径
  path : String
  /// 缩进层级（根为 0）
  depth : Int32
  /// 目录才有折叠概念
  is_dir : Bool
  /// 文件大小；目录为 0
  size : Int32
  /// 归属层
  layer : Int32
} derive(Eq, Debug)

///|
/// 看树的状态机。
///
/// `collapsed` 存「被收起的目录路径」而不是「展开过的」：新出现的目录默认展开，
/// 这符合看镜像的直觉（想看的是全貌，不是一层层点开）。
pub(all) struct TreeView {
  /// 当前用来渲染的层号
  mut layer : Int32
  /// 层总数
  total_layers : Int32
  /// 层内全量行（不含折叠过滤），`layer` 变化时重建
  all_rows : Array[Row]
  /// 收起的目录路径
  mut collapsed : Map[String, Unit]
  /// 过滤后的可见行
  mut visible : Array[Row]
  /// 光标在 `visible` 里的下标
  mut cursor : Int32
  /// 垂直滚动偏移（可视区第一行对应 `visible` 的第几项）
  mut offset : Int32
  /// 可视区行数；由画帧时按布局回填，键盘翻页要用
  mut page_height : Int32
} derive(Debug)

///|
/// 从一棵树建视图。`total_layers` 只用于状态栏显示。
pub fn TreeView::from_tree(
  tree : @layer_tree.FileTree,
  layer : Int32,
  total_layers : Int32,
) -> TreeView {
  let rows = flatten(tree)
  let view = {
    layer,
    total_layers,
    all_rows: rows,
    collapsed: {},
    visible: [],
    cursor: 0,
    offset: 0,
    page_height: 0,
  }
  view.refresh()
  view
}

///|
/// 把树按路径字典序拍平成行。`FileTree::paths()` 已排好序，
/// 这里补上「每个路径的深度」——渲染缩进与折叠过滤都靠它。
fn flatten(tree : @layer_tree.FileTree) -> Array[Row] {
  let rows = []
  for path in tree.paths() {
    // 根节点 `/` 不渲染成行，它是所有行的公共前缀
    if path == "/" {
      continue
    }
    let node = match tree.get(path) {
      Some(node) => node
      None => continue
    }
    rows.push({
      path,
      // `/usr/bin/sh` 深度是 3；`/` 自身已排除，用去掉前导 `/` 后的段数
      depth: segment_count(path),
      is_dir: node.is_dir(),
      size: node.size,
      layer: node.layer,
    })
  }
  rows
}

///|
/// 路径的层级：`/usr/bin` → 2。
fn segment_count(path : String) -> Int32 {
  let mut count = 0
  for char in path {
    if char == '/' {
      count = count + 1
    }
  }
  count
}

///|
/// 重建可见行：按 `collapsed` 过滤掉被收起目录的后代。
///
/// 光标不丢：过滤后按原光标那行的路径重新定位；路径没了（被折叠掉的），
/// 就退到它最近的一个还活着的祖先。
pub fn TreeView::refresh(self : TreeView) -> Unit {
  let cursor_path = self.cursor_path()
  let visible = []
  for row in self.all_rows {
    if self.is_hidden(row.path) {
      continue
    }
    visible.push(row)
  }
  self.visible = visible
  let target : Int32? = match cursor_path {
    Some(path) => self.index_of_path(path)
    None => Some(0)
  }
  let index = match target {
    Some(index) => index
    None => nearest_visible(self.visible, self.cursor)
  }
  self.cursor = clamp(index, 0, self.visible.length() - 1)
  self.clamp_offset()
}

///|
/// 当前光标行的路径（外部只读入口）。
pub fn TreeView::cursor_path_from_visible(self : TreeView) -> String? {
  self.cursor_path()
}

///|
/// 当前光标行的路径。
fn TreeView::cursor_path(self : TreeView) -> String? {
  if self.cursor < 0 || self.cursor >= self.visible.length() {
    return None
  }
  Some(self.visible[self.cursor].path)
}

///|
/// 找某路径在可见行里的下标；路径不可见（或不存在）时给 `None`。
pub fn TreeView::index_of_path(self : TreeView, path : String) -> Int32? {
  for index, row in self.visible {
    if row.path == path {
      return Some(index)
    }
  }
  None
}

///|
/// 路径是否被某个祖先目录收起。
///
/// 逐级往上找祖先，命中 `collapsed` 就算隐藏；根路径不会被收起。
fn TreeView::is_hidden(self : TreeView, path : String) -> Bool {
  let mut current = path
  while true {
    let parent = @layer_tree.parent_path(current)
    if parent == "" || parent == current || parent == "/" {
      return false
    }
    if self.collapsed.contains(parent) {
      return true
    }
    current = parent
  }
  false
}

///|
/// 把光标移到第 `index` 行，并保证它在可视区内。
pub fn TreeView::move_to(self : TreeView, index : Int32) -> Unit {
  self.cursor = clamp(index, 0, self.visible.length() - 1)
  self.clamp_offset()
}

///|
/// 光标下移。
pub fn TreeView::move_down(self : TreeView) -> Unit {
  self.move_to(self.cursor + 1)
}

///|
/// 光标上移。
pub fn TreeView::move_up(self : TreeView) -> Unit {
  self.move_to(self.cursor - 1)
}

///|
/// 跳到底。
pub fn TreeView::move_to_end(self : TreeView) -> Unit {
  self.move_to(self.visible.length() - 1)
}

///|
/// 跳到顶。
pub fn TreeView::move_to_home(self : TreeView) -> Unit {
  self.move_to(0)
}

///|
/// 翻页：按可视行数前进/后退，末行夹在边界内。
pub fn TreeView::page_down(self : TreeView, page : Int32) -> Unit {
  self.move_to(self.cursor + max(page, 1))
}

///|
/// 向上翻页。
pub fn TreeView::page_up(self : TreeView, page : Int32) -> Unit {
  self.move_to(self.cursor - max(page, 1))
}

///|
/// 切换光标所在目录的展开状态；非目录行不动。
pub fn TreeView::toggle(self : TreeView) -> Unit {
  if self.cursor < 0 || self.cursor >= self.visible.length() {
    return
  }
  let row = self.visible[self.cursor]
  if !row.is_dir {
    return
  }
  if self.collapsed.contains(row.path) {
    self.collapsed.remove(row.path)
  } else {
    self.collapsed.set(row.path, ())
  }
  self.refresh()
}

///|
/// 收起光标所在目录（`←`）；已经收起就跳到父目录。
pub fn TreeView::collapse(self : TreeView) -> Unit {
  if self.cursor < 0 || self.cursor >= self.visible.length() {
    return
  }
  let row = self.visible[self.cursor]
  if row.is_dir && !self.collapsed.contains(row.path) {
    self.collapsed.set(row.path, ())
    self.refresh()
    return
  }
  self.go_parent()
}

///|
/// 展开光标所在目录（`→`）；已经是展开的目录就下到第一个子行。
pub fn TreeView::expand(self : TreeView) -> Unit {
  if self.cursor < 0 || self.cursor >= self.visible.length() {
    return
  }
  let row = self.visible[self.cursor]
  if row.is_dir && self.collapsed.contains(row.path) {
    self.collapsed.remove(row.path)
    self.refresh()
    return
  }
  self.move_down()
}

///|
/// 跳到父目录那一行；已在顶层就不动。
fn TreeView::go_parent(self : TreeView) -> Unit {
  if self.cursor < 0 || self.cursor >= self.visible.length() {
    return
  }
  let depth = self.visible[self.cursor].depth
  if depth <= 1 {
    return
  }
  let mut index = self.cursor - 1
  while index >= 0 {
    if self.visible[index].depth < depth {
      self.move_to(index)
      return
    }
    index = index - 1
  }
}

///|
/// 保证光标在 [offset, offset + page) 内；`page <= 0` 时退化成「保证 offset 不越过光标」。
pub fn TreeView::clamp_offset(self : TreeView) -> Unit {
  let page = self.page_size()
  if page <= 0 {
    return
  }
  if self.cursor < self.offset {
    self.offset = self.cursor
  }
  let bottom = self.offset + page - 1
  if self.cursor > bottom {
    self.offset = self.cursor - page + 1
  }
  let max_offset = max(self.visible.length() - page, 0)
  self.offset = clamp(self.offset, 0, max_offset)
}

///|
/// 可视行数；由画帧时回填（布局决定），未设时按 0 处理。
pub fn TreeView::page_size(self : TreeView) -> Int32 {
  self.page_height
}

///|
pub extend Row with Eq::{equal, not_equal}

///|
pub extend Row with @debug.Debug::{to_repr}

///|
pub extend TreeView with @debug.Debug::{to_repr}
