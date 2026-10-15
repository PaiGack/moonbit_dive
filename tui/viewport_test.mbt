///|
/// 内容放得下时不滚。
test "viewport does not scroll when the content fits" {
  let view = Viewport::new(5, 10)
  assert_eq(view.max_offset(), 0)
  view.scroll_by(3)
  assert_eq(view.offset, 0)
  assert_eq(view.line_at(0), Some(0))
  assert_eq(view.line_at(4), Some(4))
  assert_eq(view.line_at(5), None)
}

///|
/// 偏移夹在 `[0, content - window]`：滚到底不会再往下。
test "viewport clamps offsets to the content" {
  let view = Viewport::new(20, 5)
  assert_eq(view.max_offset(), 15)
  view.scroll_by(100)
  assert_eq(view.offset, 15)
  view.scroll_by(-100)
  assert_eq(view.offset, 0)
}

///|
/// 翻页按窗口高度走，末页不越过最大偏移。
test "viewport pages by the window height" {
  let view = Viewport::new(20, 5)
  view.scroll_page(1)
  assert_eq(view.offset, 4)
  view.scroll_page(1)
  assert_eq(view.offset, 8)
  view.to_bottom()
  assert_eq(view.offset, 15)
  view.scroll_page(1)
  assert_eq(view.offset, 15)
  view.scroll_page(-1)
  assert_eq(view.offset, 11)
}

///|
/// 内容变短（换了光标）时偏移要跟着收回来，不然窗口里是空的。
test "viewport re-clamps when the content shrinks" {
  let view = Viewport::new(20, 5)
  view.to_bottom()
  assert_eq(view.offset, 15)
  view.set_content(3)
  assert_eq(view.max_offset(), 0)
  assert_eq(view.offset, 0)
  assert_eq(view.line_at(2), Some(2))
  assert_eq(view.line_at(3), None)
}

///|
/// 窗口至少一行：窗口为 0 时不该出现「永远滚不动」的死状态。
test "viewport keeps a minimum window of one line" {
  let view = Viewport::new(3, 0)
  assert_eq(view.window, 1)
  assert_eq(view.max_offset(), 2)
}
