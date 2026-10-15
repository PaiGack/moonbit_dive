///|
/// 标准 80x24：顶部标题、底部状态、左右分栏、每栏带边框。
test "layout splits a standard terminal into header body footer" {
  let layout = Layout::compute(80, 24)
  assert_eq(layout.header_row, 0)
  assert_eq(layout.status_row, 23)
  assert_eq(layout.body_top, 1)
  assert_eq(layout.body_bottom, 22)
  // 边框占掉上下各一行，内容区 20 行
  assert_eq(layout.body_height(), 20)
  // 左右各半，中间留一列分隔
  assert_eq(layout.left_start, 0)
  assert_eq(layout.left_end, 39)
  assert_eq(layout.right_start, 41)
  assert_eq(layout.right_end, 79)
  // 内容区再各缩一列边框
  assert_eq(layout.left_width(), 38)
  assert_eq(layout.right_width(), 37)
  // 内容起笔处跳掉边框
  assert_eq(layout.tree_inner_origin(), (1, 2))
  assert_eq(layout.detail_inner_origin(), (42, 2))
}

///|
/// 窄终端退化单栏：右栏不给，左栏吃满。
test "layout degrades to a single pane on narrow terminals" {
  let layout = Layout::compute(30, 20)
  assert_eq(layout.right_start, -1)
  assert_eq(layout.right_width(), 0)
  // 单栏也要留边框，内容区比总列数少两列
  assert_eq(layout.left_width(), 28)
  assert_true(layout.pane(PaneId::Detail) is None)
}

///|
/// 极端小窗不崩：行数压到极限也要有可用布局。
test "layout survives tiny terminals" {
  let layout = Layout::compute(1, 1)
  assert_true(layout.cols >= 1)
  assert_true(layout.rows >= 1)
  assert_true(layout.body_height() >= 1)
  assert_true(layout.left_width() >= 1)
}

///|
/// 非正尺寸兜底成 1。
test "layout clamps non-positive sizes" {
  let layout = Layout::compute(0, 0)
  assert_eq(layout.cols, 1)
  assert_eq(layout.rows, 1)
}

///|
/// 面板矩形：外框落在屏幕内，内容区不越过外框。
test "panes carry rects, borders and focus flags" {
  let layout = Layout::compute(80, 24)
  let tree = layout.pane(PaneId::Tree).unwrap()
  assert_eq(tree.rect, { left: 0, top: 1, right: 39, bottom: 22, })
  assert_true(tree.bordered)
  assert_true(tree.focusable)
  assert_eq(tree.inner_width(), 38)
  assert_eq(tree.inner_height(), 20)
  let detail = layout.pane(PaneId::Detail).unwrap()
  assert_true(detail.focusable)
  // 状态行不画框、不接焦点：它只有一行，画了框就没内容了
  let status = layout.pane(PaneId::Status).unwrap()
  assert_false(status.bordered)
  assert_false(status.focusable)
  assert_eq(status.rect.height(), 1)
}

///|
/// 帮助浮层：占了主体下半部分，同时把主体收窄，两者不重叠。
test "help overlay takes the lower half of the body" {
  let plain = Layout::compute(80, 24)
  let with_help = Layout::compute(80, 24, help_visible=true)
  assert_true(with_help.help_visible)
  let help = with_help.pane(PaneId::Help).unwrap()
  assert_true(help.bordered)
  assert_true(help.rect.height() >= 3)
  // 主体让位：帮助面板顶边在主体最后一行之后
  assert_true(with_help.body_bottom < help.rect.top)
  assert_eq(with_help.body_bottom, help.rect.top - 1)
  // 没展开时不留浮层
  assert_true(plain.pane(PaneId::Help) is None)
  assert_false(plain.help_visible)
  assert_eq(with_help.help_inner_origin(), Some((1, help.rect.top + 1)))
  assert_eq(plain.help_inner_origin(), None)
}

///|
/// 小窗下帮助浮层放不下就不放：留出「只剩主体」比挤成一条线有用。
test "help overlay is dropped when the body is too short" {
  let layout = Layout::compute(80, 4, help_visible=true)
  assert_false(layout.help_visible)
  assert_true(layout.pane(PaneId::Help) is None)
}

///|
/// 关边框时内容区吃满整块矩形——`with_border=false` 是给测试与极窄屏留的退路。
test "borderless layout gives the whole rect to the content" {
  let layout = Layout::compute(80, 24, with_border=false)
  assert_eq(layout.left_width(), 40)
  assert_eq(layout.right_width(), 39)
  assert_eq(layout.body_height(), 22)
  let tree = layout.pane(PaneId::Tree).unwrap()
  assert_false(tree.bordered)
  assert_eq(tree.inner_left(), tree.rect.left)
}

///|
/// 矩形退化时不出现负宽高（负数会顺着渲染层传下去，容易在 `truncate` 里出事）。
test "degenerate rects report zero size" {
  let empty : Rect = { left: 0, top: 1, right: -1, bottom: 1, }
  assert_eq(empty.width(), 0)
  assert_eq(empty.height(), 1)
  let layout = Layout::compute(20, 10)
  assert_eq(layout.detail_pane.width(), 0)
}
