///|
/// 焦点在两个面板之间正向循环。
async test "focus cycles forward through the focusable panes" {
  assert_eq(Focus::Tree.next(), Focus::Detail)
  assert_eq(Focus::Detail.next(), Focus::Tree)
}

///|
/// 反向循环。
async test "focus cycles backward" {
  assert_eq(Focus::Tree.prev(), Focus::Detail)
  assert_eq(Focus::Detail.prev(), Focus::Tree)
}

///|
/// 焦点顺序里只有会接交互的面板：状态行 / 帮助浮层不参与。
async test "focus order excludes read-only surfaces" {
  let order = focus_order()
  assert_eq(order.length(), 2)
  assert_true(order.contains(Focus::Tree))
  assert_true(order.contains(Focus::Detail))
}

///|
/// 窄屏下详情栏没有位置，但焦点留在它身上不算错——
/// 拉到足够宽之后面板会回来，焦点不该被硬拽走。
async test "focus survives losing the detail pane on a narrow terminal" {
  let narrow = Layout::compute(30, 20)
  assert_false(focus_is_visible(Focus::Detail, narrow))
  assert_true(focus_is_visible(Focus::Tree, narrow))
  let wide = Layout::compute(120, 40)
  assert_true(focus_is_visible(Focus::Detail, wide))
}

///|
/// 焦点映射到面板 id，渲染层据此决定谁的标题高亮。
async test "focus maps to a pane id" {
  assert_eq(focus_pane_id(Focus::Tree), PaneId::Tree)
  assert_eq(focus_pane_id(Focus::Detail), PaneId::Detail)
}
