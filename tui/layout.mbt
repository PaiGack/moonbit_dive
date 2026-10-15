///|
/// 一帧画面的分栏。
///
/// 参照 dive 的排布：顶部标题 / 主体左右分栏（左树、右详情）/ 底部状态行。
/// 非全屏形态下没有「外层框」——终端自己占着屏幕，画一圈边框只是浪费列数，
/// 这里只用一行标题 + 一行状态行把内容夹住。
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
} derive(Eq, Debug)

///|
/// 最小可用列宽：再窄就只剩树，右栏退化掉，别把两个字宽的面板挤成竖条。
let min_right_width : Int32 = 28

///|
/// 从终端尺寸算出分栏。
///
/// 行数不足 3 时（极端小窗）压缩成「只剩树区」，不 crash：
/// 布局函数不许抛错，否则每帧都要处理错误路径，画面代码会被错误处理淹没。
pub fn Layout::compute(cols : Int32, rows : Int32) -> Layout {
  let cols = max(cols, 1)
  let rows = max(rows, 1)
  let header_row = 0
  let status_row = max(rows - 1, 0)
  let body_top = min(1, rows - 1)
  let body_bottom = max(status_row - 1, body_top)
  // 默认对半分；右栏太窄就整体让给左栏
  let half = cols / 2
  let has_right = cols >= min_right_width * 2 && cols >= 40
  let (left_end, right_start, right_end) = if has_right {
    (half - 1, half + 1, cols - 1)
  } else {
    (cols - 1, -1, -1)
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
  }
}

///|
/// 左栏可用宽度。
pub fn Layout::left_width(self : Layout) -> Int32 {
  max(self.left_end - self.left_start + 1, 1)
}

///|
/// 右栏可用宽度；退化时为 0。
pub fn Layout::right_width(self : Layout) -> Int32 {
  if self.right_start < 0 {
    0
  } else {
    max(self.right_end - self.right_start + 1, 0)
  }
}

///|
/// 主体可视行数。
pub fn Layout::body_height(self : Layout) -> Int32 {
  max(self.body_bottom - self.body_top + 1, 1)
}

///|
pub extend Layout with Eq::{equal, not_equal}

///|
pub extend Layout with @debug.Debug::{to_repr}
