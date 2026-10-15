///|
/// L1 分栏布局引擎。
///
/// 一帧由若干**面板**（`Pane`）拼成：顶部标题 / 主体左右两块 / 底部状态行 /
/// 帮助面板（可切换的浮层）。路径 A 里这一层只是「算几个数」，全屏形态要
/// 支撑三件它当时不需要的事：
///
/// - **边框**：全屏占的是 alternate screen，画一圈框才把「这是应用」和
///   「这是 shell 输出」分开；`Pane::inner_*` 把内容区从框里算出来
/// - **焦点**：多面板要能 Tab 切换，每个面板得有自己的可聚焦标记与标题
/// - **窄屏退化**：右栏挤不下就退成单栏，帮助浮层挤不下就只留一行提示
///
/// 这一层是纯计算，不碰终端。`render.mbt` 按结果画，`app.mbt` 用
/// `body_height()` 回填翻页步长。
pub(all) enum PaneId {
  Tree
  Detail
  Status
  Help
  /// 只有一行（或多行）提示的浮层，比如「放不下」/「没有数据」
  Popup
} derive(Eq, Debug)

///|
/// 一块矩形区域（含边框）。`right` / `bottom` 是**闭区间**，
/// 与屏幕坐标一致，免得每处都写一次 `-1`。
pub(all) struct Rect {
  left : Int32
  top : Int32
  right : Int32
  bottom : Int32
} derive(Eq, Debug)

///|
pub fn Rect::width(self : Rect) -> Int32 {
  max(self.right - self.left + 1, 0)
}

///|
pub fn Rect::height(self : Rect) -> Int32 {
  max(self.bottom - self.top + 1, 0)
}

///|
/// 单个面板的定位。`bordered` 的面板内容区比外框各缩一列/一行。
pub(all) struct Pane {
  id : PaneId
  rect : Rect
  /// 是否画边框
  bordered : Bool
  /// 边框里的标题（画在左上角），空串表示不写
  title : String
  /// 能否被 Tab 聚焦（状态行 / 帮助浮层不接焦点）
  focusable : Bool
} derive(Eq, Debug)

///|
/// 内容区左边界：有框就跳掉左边框那一列。
pub fn Pane::inner_left(self : Pane) -> Int32 {
  if self.bordered {
    self.rect.left + 1
  } else {
    self.rect.left
  }
}

///|
pub fn Pane::inner_right(self : Pane) -> Int32 {
  if self.bordered {
    self.rect.right - 1
  } else {
    self.rect.right
  }
}

///|
pub fn Pane::inner_top(self : Pane) -> Int32 {
  if self.bordered {
    self.rect.top + 1
  } else {
    self.rect.top
  }
}

///|
pub fn Pane::inner_bottom(self : Pane) -> Int32 {
  if self.bordered {
    self.rect.bottom - 1
  } else {
    self.rect.bottom
  }
}

///|
/// 内容区宽度；框太窄（放不下两列边框）时退化成 1，不要把负数传下去。
pub fn Pane::inner_width(self : Pane) -> Int32 {
  max(self.inner_right() - self.inner_left() + 1, 1)
}

///|
/// 内容区高度；退化规则同 `inner_width`。
pub fn Pane::inner_height(self : Pane) -> Int32 {
  max(self.inner_bottom() - self.inner_top() + 1, 1)
}

///|
/// 一帧的分栏结果。
///
/// 字段仍是老的几个（`render.mbt` 里到处在用），但语义升级成「主面板矩形」，
/// 另加 `panes` 给边框与焦点查询。`Layout::compute` 是唯一入口。
pub(all) struct Layout {
  /// 终端总列数 / 行数
  cols : Int32
  rows : Int32
  /// 标题行所在行（0 起）
  header_row : Int32
  /// 主体第一行 / 最后一行（含）
  body_top : Int32
  body_bottom : Int32
  /// 左栏列区间 [left_start, left_end]
  left_start : Int32
  left_end : Int32
  /// 右栏列区间 [right_start, right_end]；右栏宽度不足时为 -1（退化单栏）
  right_start : Int32
  right_end : Int32
  /// 状态行
  status_row : Int32
  /// 各面板（含边框与可聚焦标记）
  panes : Array[Pane]
  /// 帮助浮层是否展开；展开时它盖在主体上，主体按 `body_bottom` 收窄
  help_visible : Bool
  /// 主体区域的外框；窄屏退化时右边界收到左栏
  tree_pane : Rect
  /// 详情面板外框；退化时为 0 宽（`width() == 0`）
  detail_pane : Rect
  /// 帮助浮层外框；没展开时 0 高
  help_pane : Rect
} derive(Eq, Debug)

///|
/// 最小可用列宽：再窄就只剩树，右栏退化掉，别把两个字宽的面板挤成竖条。
let min_right_width : Int32 = 28

///|
/// 分隔两栏的竖线所在的列数（左栏右端到右栏左端之间留 1 列）。
let gap_width : Int32 = 1

///|
/// 从终端尺寸算出分栏。
///
/// 行数不足 3 时（极端小窗）压缩成「只剩树区」，不 crash：
/// 布局函数不许抛错，否则每帧都要处理错误路径，画面代码会被错误处理淹没。
///
/// `help_visible` 打开时，帮助浮层占主体下半部分（至多一半，最少 3 行），
/// 铺满宽度——比把主体挤窄更好读，也不会把详情面板压没。
pub fn Layout::compute(
  cols : Int32,
  rows : Int32,
  with_border~ : Bool = true,
  help_visible~ : Bool = false,
) -> Layout {
  let cols = max(cols, 1)
  let rows = max(rows, 1)
  let header_row = 0
  let status_row = max(rows - 1, 0)
  let body_top = min(1, rows - 1)
  let mut body_bottom = max(status_row - 1, body_top)
  // 帮助浮层从主体里切一块出来（至多一半，至少 3 行）。
  // 主体 < 4 行时不给浮层：切完主体只剩一两行，读树都读不成，
  // 不如把整个主体让给树，帮助内容按状态行提示触达。
  let mut help_pane : Rect = { left: 0, top: 0, right: -1, bottom: -1, }
  let body_height_total = body_bottom - body_top + 1
  if help_visible && body_height_total >= 4 {
    let help_height = clamp(body_height_total / 2, 3, body_height_total - 1)
    let help_top = body_bottom - help_height + 1
    help_pane = {
      left: 0,
      top: help_top,
      right: cols - 1,
      bottom: body_bottom,
    }
    body_bottom = help_top - 1
  }
  // 默认对半分；右栏太窄就整体让给左栏
  let half = cols / 2
  let has_right = cols >= min_right_width * 2 + gap_width && cols >= 40
  let (left_end, right_start, right_end) = if has_right {
    (half - 1, half + gap_width, cols - 1)
  } else {
    (cols - 1, -1, -1)
  }
  let tree_rect : Rect = {
    left: 0,
    top: body_top,
    right: left_end,
    bottom: body_bottom,
  }
  let detail_rect : Rect = if has_right {
    { left: right_start, top: body_top, right: right_end, bottom: body_bottom, }
  } else {
    // 退化的空矩形：`width() == 0`，画的时候整块跳过
    { left: 0, top: body_top, right: -1, bottom: body_top, }
  }
  let panes : Array[Pane] = [
    {
      id: PaneId::Tree,
      rect: tree_rect,
      bordered: with_border,
      title: "files",
      focusable: true,
    },
  ]
  if has_right {
    panes.push({
      id: PaneId::Detail,
      rect: detail_rect,
      bordered: with_border,
      title: "layer detail",
      focusable: true,
    })
  }
  panes.push({
    id: PaneId::Status,
    rect: { left: 0, top: status_row, right: cols - 1, bottom: status_row, },
    // 状态行贴着屏幕底边，画框反而占掉唯一一行内容
    bordered: false,
    title: "",
    focusable: false,
  })
  if help_pane.height() > 0 {
    panes.push({
      id: PaneId::Help,
      rect: help_pane,
      bordered: with_border,
      title: "keys",
      focusable: false,
    })
  }
  {
    cols,
    rows,
    header_row,
    body_top,
    body_bottom,
    left_start: 0,
    left_end,
    right_start,
    right_end,
    status_row,
    panes,
    // 浮层真的建出来了才算「展开」：放不下时按没展开处理，
    // 免得渲染层兴冲冲去画一块 0 高的框
    help_visible: help_pane.height() > 0,
    tree_pane: tree_rect,
    detail_pane: detail_rect,
    help_pane,
  }
}

///|
/// 按 id 取面板；找不到给 `None`（比如窄屏下的详情栏）。
pub fn Layout::pane(self : Layout, id : PaneId) -> Pane? {
  for pane in self.panes {
    if pane.id == id {
      return Some(pane)
    }
  }
  None
}

///|
/// 左栏可用宽度（内容区，不含边框）。
pub fn Layout::left_width(self : Layout) -> Int32 {
  if self.tree_pane.width() == 0 {
    return 1
  }
  match self.pane(PaneId::Tree) {
    Some(pane) => pane.inner_width()
    None => 1
  }
}

///|
/// 右栏可用宽度（内容区，不含边框）；退化时为 0。
pub fn Layout::right_width(self : Layout) -> Int32 {
  if self.right_start < 0 {
    return 0
  }
  match self.pane(PaneId::Detail) {
    Some(pane) => pane.inner_width()
    None => 0
  }
}

///|
/// 主体可视行数（不含边框）。
pub fn Layout::body_height(self : Layout) -> Int32 {
  match self.pane(PaneId::Tree) {
    Some(pane) => pane.inner_height()
    None => max(self.body_bottom - self.body_top + 1, 1)
  }
}

///|
/// 树内容区的首行 / 首列：渲染直接从这个坐标起笔。
pub fn Layout::tree_inner_origin(self : Layout) -> (Int32, Int32) {
  match self.pane(PaneId::Tree) {
    Some(pane) => (pane.inner_left(), pane.inner_top())
    None => (0, self.body_top)
  }
}

///|
/// 详情内容区的首行 / 首列。
pub fn Layout::detail_inner_origin(self : Layout) -> (Int32, Int32) {
  match self.pane(PaneId::Detail) {
    Some(pane) => (pane.inner_left(), pane.inner_top())
    None => (self.right_start, self.body_top)
  }
}

///|
/// 帮助浮层内容区的首行 / 首列；没展开时给 `None`。
pub fn Layout::help_inner_origin(self : Layout) -> (Int32, Int32)? {
  if !self.help_visible {
    return None
  }
  match self.pane(PaneId::Help) {
    Some(pane) => Some((pane.inner_left(), pane.inner_top()))
    None => None
  }
}

///|
pub extend PaneId with Eq::{equal, not_equal}

///|
pub extend Rect with Eq::{equal, not_equal}

///|
pub extend Pane with Eq::{equal, not_equal}

///|
pub extend Layout with Eq::{equal, not_equal}

///|
pub extend PaneId with @debug.Debug::{to_repr}

///|
pub extend Rect with @debug.Debug::{to_repr}

///|
pub extend Pane with @debug.Debug::{to_repr}

///|
pub extend Layout with @debug.Debug::{to_repr}
