///|
/// 标准 80x24：顶部标题、底部状态、左右分栏。
test "layout splits a standard terminal into header body footer" {
  let layout = Layout::compute(80, 24)
  assert_eq(layout.header_row, 0)
  assert_eq(layout.status_row, 23)
  assert_eq(layout.body_top, 1)
  assert_eq(layout.body_bottom, 22)
  assert_eq(layout.body_height(), 22)
  // 左右各半，中间留一列分隔
  assert_eq(layout.left_start, 0)
  assert_eq(layout.left_end, 39)
  assert_eq(layout.right_start, 41)
  assert_eq(layout.right_end, 79)
  assert_eq(layout.left_width(), 40)
  assert_eq(layout.right_width(), 39)
}

///|
/// 窄终端退化单栏：右栏不给，左栏吃满。
test "layout degrades to a single pane on narrow terminals" {
  let layout = Layout::compute(30, 20)
  assert_eq(layout.right_start, -1)
  assert_eq(layout.right_width(), 0)
  assert_eq(layout.left_width(), 30)
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
