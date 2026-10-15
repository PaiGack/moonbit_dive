///|
/// L2 组件层：把「一块面板怎么画」从 `render.mbt` 里抽出来。
///
/// 每个组件都是 `(screen, pane, payload)` 的纯函数，自己算内容区、
/// 自己收边、自己画标题——`render.mbt` 变成一行一个组件的拼装。
/// 抽这一层的实际收益不是「少写代码」，而是**一块面板的几何错了只查一个地方**：
/// 路径 A 时左栏/右栏的坐标散在 `draw_tree_pane` / `draw_detail_pane` 里各算一遍，
/// 加边框时两边都要改一遍坐标偏移。
///
/// 焦点只影响「标题栏有没有反白标记」这一件事，因此组件不必知道全局焦点顺序，
/// 只要 `focused` 一个布尔值——焦点顺序归 `focus.mbt` 管。
///
/// 画框用 ASCII（`+` `-` `|`），不引 Unicode 制表符：与 `width.mbt` 的口径一致
/// （ASCII 一律一列），也不会在某些终端字体下变成豆腐块。
pub fn paint_pane(screen : Screen, pane : Pane, focused : Bool) -> Unit {
  if pane.bordered {
    paint_border(screen, pane, focused)
  }
}

///|
/// 画一圈边框 + 左上角标题。
///
/// 标题形如 `─ files ────`（聚焦时前面加 `>`）。1 列 × 1 行的退化框直接跳过：
/// 画一条线出来的框比不画更难看。
fn paint_border(screen : Screen, pane : Pane, focused : Bool) -> Unit {
  let rect = pane.rect
  if rect.width() < 2 || rect.height() < 2 {
    return
  }
  let (left, right) = (rect.left, rect.right)
  let (top, bottom) = (rect.top, rect.bottom)
  // 上下两条横边
  for col = left + 1; col < right; col = col + 1 {
    screen.set(col, top, '-')
    screen.set(col, bottom, '-')
  }
  // 左右两条竖边
  for row = top + 1; row < bottom; row = row + 1 {
    screen.set(left, row, '|')
    screen.set(right, row, '|')
  }
  screen.set(left, top, '+')
  screen.set(right, top, '+')
  screen.set(left, bottom, '+')
  screen.set(right, bottom, '+')
  // 标题压在顶边上（从 left+2 起，给两个角留位置）
  if pane.title.is_empty() {
    return
  }
  let label = if focused { ">\{pane.title} " } else { "\{pane.title} " }
  let budget = rect.width() - 3
  if budget <= 0 {
    return
  }
  screen.write_text(left + 2, top, " " + truncate_to_width(label, budget))
}

///|
/// 面板内容区逐行清空。带框的面板只清内容区，别把框擦掉。
pub fn clear_pane(screen : Screen, pane : Pane) -> Unit {
  let top = pane.inner_top()
  let bottom = pane.inner_bottom()
  let left = pane.inner_left()
  let right = pane.inner_right()
  if right < left {
    return
  }
  for row = top; row <= bottom; row = row + 1 {
    for col = left; col <= right; col = col + 1 {
      screen.set(col, row, ' ')
    }
  }
}

///|
/// 面板内容区放不下的行数提示（`3/120`），画在右下角。
pub fn paint_overflow_hint(
  screen : Screen,
  pane : Pane,
  shown : Int32,
  total : Int32,
) -> Unit {
  if total <= shown || shown <= 0 {
    return
  }
  let hint = "\{shown}/\{total}"
  let width = pane.inner_width()
  let hint_width = display_width(hint)
  if hint_width >= width {
    return
  }
  screen.write_text(
    pane.inner_right() - hint_width + 1,
    pane.inner_bottom(),
    hint,
  )
}
