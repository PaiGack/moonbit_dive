///|
/// L3 焦点管理：哪些面板能被 Tab 走到、现在在谁身上、下一个是谁。
///
/// 路径 A 只有一个可动的东西（树的光标），没有「焦点」这个概念。全屏形态下
/// 树与详情各自会滚，键盘得先知道「这一下是给谁的」，于是焦点必须显式化。
///
/// **状态行与帮助浮层不接焦点**：前者是只读的单行提示，后者是浮层，
/// 把 Tab 停在没有交互的面板上只会让人以为按键失灵。这条规则由
/// `Layout` 里的 `focusable` 标记表达（见 `layout.mbt`），这里只做顺序计算。
///
/// 这一层是纯函数：给定「哪些面板可聚焦」与「现在在谁身上」，算出下一个。
/// 因此焦点逻辑可以完全单测，不需要终端。
pub(all) enum Focus {
  Tree
  Detail
} derive(Eq, Debug)

///|
/// 焦点顺序：固定的两格，与 `Layout.panes` 里的顺序一致。
///
/// 用固定顺序而不是「从 `panes` 里筛」，是为了让焦点与布局解耦：
/// 窄屏下详情栏没了，焦点仍可以停在 `Detail` 上（有数据就画，
/// 没地方画就不画），这样 resize 变窄再变宽时焦点不会莫名跳走。
pub fn focus_order() -> Array[Focus] {
  [Focus::Tree, Focus::Detail]
}

///|
/// `focus` 在顺序里的下标；不在顺序里时给 0（不该发生，兜底不抛）。
fn focus_index(focus : Focus) -> Int32 {
  let order = focus_order()
  for index, item in order {
    if item == focus {
      return index
    }
  }
  0
}

///|
/// 下一个焦点（Tab / 正向循环）。
pub fn Focus::next(self : Focus) -> Focus {
  let order = focus_order()
  let index = focus_index(self)
  order[(index + 1) % order.length()]
}

///|
/// 上一个焦点（Shift+Tab / 反向循环）。
pub fn Focus::prev(self : Focus) -> Focus {
  let order = focus_order()
  let index = focus_index(self)
  let back = (index - 1 + order.length()) % order.length()
  order[back]
}

///|
/// 焦点能否落在某个面板上：布局里没有这块面板（窄屏退化掉的详情栏）时，
/// 焦点仍算「在」它身上——只是暂时无处可画，不把焦点硬拽回树上。
pub fn focus_is_visible(focus : Focus, layout : Layout) -> Bool {
  layout.pane(focus_pane_id(focus)) is Some(_)
}

///|
/// 焦点对应的面板 id。
pub fn focus_pane_id(focus : Focus) -> PaneId {
  match focus {
    Focus::Tree => PaneId::Tree
    Focus::Detail => PaneId::Detail
  }
}

///|
pub extend Focus with Eq::{equal, not_equal}

///|
pub extend Focus with @debug.Debug::{to_repr}
