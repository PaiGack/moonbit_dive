///|
/// L1 滚动视口：让「一列长内容」在固定高度的窗口里可滚。
///
/// 树那边已经有滚动（`TreeView` 的 `offset` / `clamp_offset`），但它是跟着
/// 树的状态走的；详情面板的滚动与树无关（内容是若干行文本），自己再写一份
/// `clamp` 逻辑会重复。这里把「偏移 + 夹取」抽成一个小值，两边都能用。
///
/// 只存 `offset` 与 `content` / `window` 两个计数，不持内容本体：
/// 内容是每帧现算的（详情面板依赖光标），存进来反而要处理脏数据。
pub(all) struct Viewport {
  /// 第一行内容对应的下标
  mut offset : Int32
  /// 内容总行数
  mut content : Int32
  /// 窗口行数
  mut window : Int32
} derive(Eq, Debug)

///|
pub fn Viewport::new(content : Int32, window : Int32) -> Viewport {
  { offset: 0, content: max(content, 0), window: max(window, 1), }
}

///|
/// 最大偏移；内容比窗口短时为 0。
pub fn Viewport::max_offset(self : Viewport) -> Int32 {
  max(self.content - self.window, 0)
}

///|
/// 把偏移夹回合法范围。内容行数变化（换了光标 / resize）后都要叫一次。
pub fn Viewport::clamp(self : Viewport) -> Unit {
  self.offset = clamp(self.offset, 0, self.max_offset())
}

///|
/// 相对滚动 `delta` 行。
pub fn Viewport::scroll_by(self : Viewport, delta : Int32) -> Unit {
  self.offset = self.offset + delta
  self.clamp()
}

///|
/// 翻页：按窗口高度滚动，末页会夹到最大偏移，不会滚过头。
pub fn Viewport::scroll_page(self : Viewport, direction : Int32) -> Unit {
  let step = max(self.window - 1, 1)
  self.scroll_by(if direction >= 0 { step } else { -step })
}

///|
/// 回到顶部。
pub fn Viewport::to_top(self : Viewport) -> Unit {
  self.offset = 0
}

///|
/// 到底。
pub fn Viewport::to_bottom(self : Viewport) -> Unit {
  self.offset = self.max_offset()
}

///|
/// 取窗口里第 `row`（0 起，相对窗口）行对应的内容下标；越界给 `None`。
pub fn Viewport::line_at(self : Viewport, row : Int32) -> Int32? {
  let index = self.offset + row
  if index < 0 || index >= self.content {
    return None
  }
  Some(index)
}

///|
/// 内容行数变化时更新计数（内容变短就把偏移一并夹回来）。
pub fn Viewport::set_content(self : Viewport, content : Int32) -> Unit {
  self.content = max(content, 0)
  self.clamp()
}

///|
pub extend Viewport with Eq::{equal, not_equal}

///|
pub extend Viewport with @debug.Debug::{to_repr}
