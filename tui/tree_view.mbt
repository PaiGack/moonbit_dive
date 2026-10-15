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
///
/// 每行还带一份 `RowStatus`：这一层的 diff 说它是新增/改写/删除，还是没有动过。
/// 它取自 `layer_tree` 的 `Diff`，但落在**视图状态**里而不是渲染时现查——
/// 换层、折叠、滚动都不改变「某个路径在这一层属于哪一类」，算一次就够。
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
  /// 这一层里该路径的变化类别（渲染按它上色）
  status : RowStatus
  /// 低 12 位权限。数据源里本来就有，之前没带出来（`Ctrl+B` 要看它）
  mode : Int32
  /// entry 记录的修改时间（Unix 秒），0 表示数据源没给
  mtime : Int32
} derive(Eq, Debug)

///|
/// 某条路径相对上一层的状态。
///
/// 没有 `Removed`：被删掉的路径根本不在这一层的树上，没有行可以给它上色，
/// 删除这件事由详情面板与报告回答。硬留一个画不出来的枚举值只会让渲染层
/// 多写一个永远走不到的分支。
///
/// 「先删后加同名文件」在 `Diff` 里同时出现在 `added` 与 `removed`，树上有行，
/// 按 `Added` 处理——对看树的人来说「这层写了它」比「这层删过它」更常用。
pub(all) enum RowStatus {
  Added
  Modified
  /// 这一层没动过它
  Unchanged
} derive(Eq, Debug)

///|
/// 一行降在哪一档。与 `RowStatus` 合成一张 3x2 的表，
/// `Ctrl+A/R/M/U` 四个过滤键就是从它派生出来的（`Row::in_group`）。
///
/// 没有 `Removed`：被删的路径不在这一层的树上，没有行可以给它归档。
pub(all) enum RowGroup {
  AddedOnly
  ModifiedOnly
  UnchangedOnly
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
  /// 一行是按「名字」还是按「大小」排序（`data_set_sort` 写，`all_rows` 按它重排）
  mut sort_by_size : Bool
  /// 只看某一档 diff（`Ctrl+A/R/M/U`）；`None` 表示四档都要（`Ctrl+U` 同效）
  mut filter : RowGroup?
} derive(Debug)

///|
/// 从一棵树建视图。`total_layers` 只用于状态栏显示，排序按名字。
pub fn TreeView::from_tree(
  tree : @layer_tree.FileTree,
  layer : Int32,
  total_layers : Int32,
) -> TreeView {
  TreeView::from_tree_with_diff(tree, None, layer, total_layers, false)
}

///|
/// 带本层 diff 建视图：`diff` 是这一层相对上一层的差异（`LayerView.diff`），
/// 缺省表示「不知道变了什么」，所有行按 `Unchanged` 处理（颜色就都不上）。
pub fn TreeView::from_tree_with_diff(
  tree : @layer_tree.FileTree,
  diff : @layer_tree.Diff?,
  layer : Int32,
  total_layers : Int32,
  by_size : Bool,
) -> TreeView {
  let rows = sort_rows(flatten(tree, diff), by_size)
  let view = {
    layer,
    total_layers,
    all_rows: rows,
    collapsed: {},
    visible: [],
    cursor: 0,
    offset: 0,
    page_height: 0,
    sort_by_size: by_size,
    filter: None,
  }
  view.refresh()
  view
}

///|
/// 按 `by_size` 决定行序；`false` 时保持 `flatten` 出来的路径序。
///
/// 排序规则：目录整体排在文件之前（目录自己不带大小，混在文件里按 0 排
/// 会全部沉底，读起来像「目录都没了」），两级内部各自按大小降序、
/// 同大小按路径升序。
fn sort_rows(rows : Array[Row], by_size : Bool) -> Array[Row] {
  if !by_size {
    return rows
  }
  let result = rows.copy()
  result.sort_by(row_size_order)
  result
}

///|
/// 按体积排序的比较函数：目录优先 → 体积降序 → 路径升序。
fn row_size_order(left : Row, right : Row) -> Int32 {
  if left.is_dir != right.is_dir {
    return if left.is_dir { -1 } else { 1 }
  }
  if left.size != right.size {
    return if left.size > right.size { -1 } else { 1 }
  }
  @layer_tree.path_order(left.path, right.path)
}

///|
/// 把树按路径字典序拍平成行。`FileTree::paths()` 已排好序，
/// 这里补上「每个路径的深度」——渲染缩进与折叠过滤都靠它。
fn flatten(tree : @layer_tree.FileTree, diff : @layer_tree.Diff?) -> Array[Row] {
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
    let status = match diff {
      Some(diff) => status_of(diff, path)
      None => RowStatus::Unchanged
    }
    rows.push({
      path,
      // `/usr/bin/sh` 深度是 3；`/` 自身已排除，用去掉前导 `/` 后的段数
      depth: segment_count(path),
      is_dir: node.is_dir(),
      size: node.size,
      layer: node.layer,
      status,
      mode: node.mode,
      mtime: node.mtime,
    })
  }
  rows
}

///|
/// 查一条路径在 diff 里属于哪一类。
///
/// `removed` 不用查：被删的路径已经不在树上。`added` 先查——先删后加的同名路径
/// `added` 与 `removed` 两个表里都有，按 `RowStatus` 的口径取 `added`。
///
/// 逐组线性扫而不是建 `Map`：一次建视图只查一遍这一层的路径，量级就是路径数
/// 乘常数，`Map` 的哈希与分配反而更贵。
fn status_of(diff : @layer_tree.Diff, path : String) -> RowStatus {
  if contains(diff.added, path) {
    RowStatus::Added
  } else if contains(diff.modified, path) {
    RowStatus::Modified
  } else {
    RowStatus::Unchanged
  }
}

///|
/// 路径表里的线性查找。
fn contains(paths : Array[String], path : String) -> Bool {
  for candidate in paths {
    if candidate == path {
      return true
    }
  }
  false
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
    // 过滤（`Ctrl+A/R/M/U`）在折叠之后再看：被折起来的行本来就不该出现，
    // 顺序反过来会让「过滤掉的祖先」与「折叠掉的祖先」互相打架
    if self.filter is Some(group) && !row.in_group(group) {
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
/// 当前光标那一行（拿不到给 `None`）。详情面板的属性行要用它。
pub fn TreeView::cursor_row(self : TreeView) -> Row? {
  if self.cursor < 0 || self.cursor >= self.visible.length() {
    return None
  }
  Some(self.visible[self.cursor])
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
/// 全折叠 / 全展开（`Ctrl+Space`，原版 `ToggleAllCollapseDir`）。
///
/// 「现在算不算全折叠」不看 `collapsed` 的大小，看**效果**：只要还有一行目录
/// 是摊开的，这次就是「全折叠」。理由是同名动作要幂等——按一次全折、
/// 再按一次全展，中间若因为过滤 / 换层让 `collapsed` 变得不完整，
/// 用大小去比就会在这两种状态之间抖动，看起来像没反应。
///
/// 全折叠时**光标留在原地**：跳到顶会让一屏内容整体换掉，
/// 而「折起来但仍在原处」更接近「我只是把没用的收起来」。
/// 若光标正好落在被折掉的子行上，`refresh` 会把它落到最近的可见祖先。
///
/// 先开着过滤时也照做：过滤与折叠互不覆盖，关掉过滤还能看到原来折到哪。
pub fn TreeView::toggle_collapse_all(self : TreeView) -> Unit {
  if self.any_expanded_dir() {
    for row in self.all_rows {
      if row.is_dir {
        self.collapsed.set(row.path, ())
      }
    }
  } else {
    self.collapsed = Map([])
  }
  self.refresh()
}

///|
/// 还有没有「摊开着」的目录；一个目录都没有时给 `false`
/// （空树按「已经全折好」处理，再按一次就是全展，不会卡住）。
fn TreeView::any_expanded_dir(self : TreeView) -> Bool {
  for row in self.all_rows {
    if row.is_dir && !self.collapsed.contains(row.path) {
      return true
    }
  }
  false
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
pub extend RowStatus with @debug.Debug::{to_repr}

///|
pub extend RowStatus with Eq::{equal, not_equal}

///|
pub extend RowGroup with @debug.Debug::{to_repr}

///|
pub extend RowGroup with Eq::{equal, not_equal}

///|
pub extend Row with Eq::{equal, not_equal}

///|
pub extend Row with @debug.Debug::{to_repr}

///|
pub extend TreeView with @debug.Debug::{to_repr}

///|
/// 坐标反查：屏幕行 → 可见行下标（#51）。
///
/// 之前只有「行下标 → 屏幕行」这一个方向（渲染时 `offset + row`），
/// 鼠标落地需要反过来问一句「第 `screen_row` 行画的是哪一项」。
/// 反查和正查必须用同一份 `offset` / `page_height`：谁把这两个字段
/// 当成两套坐标，点击就会偏一行。
///
/// `screen_row` 是**内容区内的相对行**（0 起），不是终端绝对行——
/// 面板左上角在哪由 `Layout` 决定（`inner_top`），树这边不重复算布局。
/// 落在可视区外（面板上的空白格）给 `None`，调用方据此什么都不做，
/// 而不是把点击夹到首行/末行——「点空白跳到底」不是任何人的直觉。
pub fn TreeView::index_at_screen_row(
  self : TreeView,
  screen_row : Int32,
) -> Int32? {
  if screen_row < 0 {
    return None
  }
  let page = self.page_size()
  if page <= 0 || screen_row >= page {
    return None
  }
  let index = self.offset + screen_row
  if index < 0 || index >= self.visible.length() {
    return None
  }
  Some(index)
}

///|
/// 坐标反查 + 切展开态：右键点击、以及左键点目录行共用（#62）。
///
/// 返回 `false` 表示光标没落在任何可见行上（点了面板空白），
/// 调用方据此什么都不做——与 `select_at_screen_row` 一个口径。
///
/// 落在**文件行**上是「选中但不开合」：先落光标再调 `toggle`，
/// 而 `toggle` 对非目录行是空操作。所以「点文件只选中」这条等价于
/// 「点目录顺带开合」的同一段代码，不需要在这里分叉。
pub fn TreeView::toggle_fold_at_screen_row(
  self : TreeView,
  screen_row : Int32,
) -> Bool {
  if !self.select_at_screen_row(screen_row) {
    return false
  }
  self.toggle()
  true
}

///|
/// 坐标反查 + 落光标：点击/滚轮共用的落点。
///
/// 反查失败（点在空白处）时不动光标，返回 `false`，调用方据此决定
/// 要不要跟着切焦点——点空白既不该选行，也不该把焦点抢过来。
pub fn TreeView::select_at_screen_row(
  self : TreeView,
  screen_row : Int32,
) -> Bool {
  match self.index_at_screen_row(screen_row) {
    Some(index) => {
      self.move_to(index)
      true
    }
    None => false
  }
}

///|
/// 一行是否属于 `Ctrl+A/R/M/U` 的某一档。
///
/// `dive` 那边是「把不同 diff 集合的行拼起来再过滤」，本仓没有「把 added /
/// removed / modified / unmodified 四棵树拼成一张表」这一步（树本来就只有一个，
/// 删除的路径不在树上），所以这里退化成对**行自带的 `status`** 做一次判定。
/// 语义对齐：`added` 就是新增行、`modified` 就是改写行、`unmodified` 是没动过的行。
///
/// 被删掉的路径没有行，因此没有对应的一档——这一点在 `docs/p6-tui.md`
/// 的差异说明里写清楚了，不是漏做。
pub fn Row::in_group(self : Row, group : RowGroup) -> Bool {
  match group {
    RowGroup::AddedOnly => self.status == RowStatus::Added
    RowGroup::ModifiedOnly => self.status == RowStatus::Modified
    RowGroup::UnchangedOnly => self.status == RowStatus::Unchanged
  }
}

///|
/// 只要这三行里有一行属于 `group`，就不画「这类都没有」的提示。
///
/// 判空用**全量行**（`all_rows`）而不是可见行：折叠起来的目录里可能正好有
/// 唯一的 added 行，这时候说「没有新增」是假话。
pub fn TreeView::has_in_group(self : TreeView, group : RowGroup) -> Bool {
  for row in self.all_rows {
    if row.in_group(group) {
      return true
    }
  }
  false
}

///|
/// 当前是否只显示某一档（`Ctrl+A/R/M/U`）；`Ctrl+U` 是「全都要」。
///
/// 过滤与折叠是两件事，因此过滤不进 `refresh` 的 `collapsed` 判定里，
/// 而是单独一层布尔：关掉过滤要能原样回到「跟没过滤前一样」。
pub fn TreeView::only_group(self : TreeView) -> RowGroup? {
  self.filter
}

///|
/// 设 / 撤过滤档位。设成当前那一档会**切回全都要**（连按 `Ctrl+A` 两次等于没按），
/// 与 dive 的 `InvertFilter` 同效；给 `None` 就是显式清掉。
pub fn TreeView::set_filter(self : TreeView, group : RowGroup?) -> Unit {
  self.filter = match group {
    Some(next) =>
      match self.filter {
        Some(current) if current == next => None
        _ => Some(next)
      }
    None => None
  }
  self.refresh()
}
