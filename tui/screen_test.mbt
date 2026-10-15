///|
/// 新建画布默认全是空格。
test "screen starts blank" {
  let screen = Screen::new(10, 3)
  assert_eq(screen.cols, 10)
  assert_eq(screen.rows, 3)
  assert_eq(screen.get(0, 0), ' ')
  assert_eq(screen.row_string(0), "          ")
}

///|
/// 越界写读不 panic：组件不必自己算边界。
test "screen clamps out-of-range access" {
  let screen = Screen::new(5, 2)
  screen.set(-1, 0, 'x')
  screen.set(0, 99, 'x')
  screen.set(99, 0, 'x')
  assert_eq(screen.get(-5, 0), ' ')
  assert_eq(screen.get(0, 99), ' ')
  assert_eq(screen.row_string(0), "     ")
  assert_eq(screen.row_string(1), "     ")
}

///|
/// 写文本按列推进，右边界截断。
test "screen writes text and truncates at right edge" {
  let screen = Screen::new(4, 1)
  screen.write_text(0, 0, "abcdef")
  assert_eq(screen.row_string(0), "abcd")
}

///|
/// 宽字符占两列，且不会跨出右边界。
test "screen reserves two columns for wide chars" {
  let screen = Screen::new(4, 1)
  screen.write_text(0, 0, "中x")
  // 中占 0-1，x 落在 2
  assert_eq(screen.get(0, 0), '中')
  assert_eq(screen.get(2, 0), 'x')
  // 行串里的占位符不能吐出去（宽字符后半格不重复吐字节）
  assert_eq(screen.row_string(0), "中x ")
}

///|
/// 宽字符卡在最后一列时写成空格，避免撑破行宽。
test "screen writes a space when a wide char does not fit the last column" {
  let screen = Screen::new(3, 1)
  screen.write_text(2, 0, "中")
  assert_eq(screen.get(2, 0), ' ')
  assert_eq(screen.row_string(0), "   ")
}

///|
/// 写过的格子进脏集。
test "screen marks written cells dirty" {
  let screen = Screen::new(3, 1)
  assert_false(screen.dirty[0])
  screen.set(0, 0, 'a')
  assert_true(screen.dirty[0])
  assert_false(screen.dirty[1])
}

///|
/// resize 同尺寸是恒等，不同尺寸重建。
test "screen resize rebuilds only when dimensions change" {
  let screen = Screen::new(3, 2)
  screen.set(0, 0, 'a')
  let same = screen.resize(3, 2)
  // 同尺寸返回原对象，写入不丢
  same.set(1, 0, 'b')
  assert_eq(screen.get(1, 0), 'b')
  let bigger = screen.resize(5, 4)
  assert_eq(bigger.cols, 5)
  assert_eq(bigger.rows, 4)
  assert_eq(bigger.get(0, 0), ' ')
}

///|
/// resize 用非正尺寸兜底成 1×1，别造出零长度数组。
test "screen resize clamps non-positive sizes" {
  let screen = Screen::new(3, 3)
  let tiny = screen.resize(0, -5)
  assert_eq(tiny.cols, 1)
  assert_eq(tiny.rows, 1)
}
