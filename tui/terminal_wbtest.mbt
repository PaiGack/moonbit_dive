///|
/// 基线克隆不带脏标记：脏标记属于「这一帧写过什么」，拷过去会让下一帧全量重画。
async test "clone_screen keeps cells but clears dirty" {
  let screen = Screen::new(3, 2)
  screen.set(0, 0, "a")
  screen.set(2, 1, "b")
  let clone = clone_screen(screen)
  assert_eq(clone.get(0, 0), "a")
  assert_eq(clone.get(2, 1), "b")
  assert_eq(clone.cols, 3)
  assert_eq(clone.rows, 2)
  assert_false(clone.dirty[0])
  assert_false(clone.dirty[5])
}

///|
/// 没写过（不脏）的格子不算差异，即使基线与当前不同。
async test "is_dirty requires both a write and a change" {
  let current = Screen::new(3, 1)
  let baseline = Screen::new(3, 1)
  // 基线有内容、当前是空格，但当前没写过 → 不算脏
  assert_false(is_dirty(current, baseline, 0, 0))
  current.set(0, 0, "a")
  assert_true(is_dirty(current, baseline, 0, 0))
  // 写回原值：脏了但没变 → 不必重画
  let same = Screen::new(3, 1)
  let same_base = Screen::new(3, 1)
  same.set(1, 0, "x")
  same_base.set(1, 0, "x")
  assert_false(is_dirty(same, same_base, 1, 0))
}

///|
/// 尺寸放大后，超出旧基线范围的格子一律算脏。
async test "is_dirty treats cells outside the baseline as changed" {
  let current = Screen::new(4, 2)
  let baseline = Screen::new(2, 1)
  current.set(3, 1, "z")
  assert_true(is_dirty(current, baseline, 3, 1))
}

///|
/// 连续段的取字：占位符（宽字符后半格）不吐字节。
async test "segment_string skips wide-char placeholders" {
  let screen = Screen::new(6, 1)
  screen.write_text(0, 0, "中x")
  // 区间 [0,2]：中 → 占位符（跳过） → x
  assert_eq(segment_string(screen, 0, 2, 0), "中x")
  // 只取占位符那一格时给空串，不会打印出控制字符
  assert_eq(segment_string(screen, 1, 1, 0), "")
}

///|
/// 区间宽度按列补齐：末尾的空白也要吐出来，否则光标推进量会短、后面内容左移。
async test "segment_string pads to the interval width" {
  let screen = Screen::new(5, 1)
  screen.set(0, 0, "a")
  // 区间 [0,3] 是 4 列，只有首格有内容
  let segment = segment_string(screen, 0, 3, 0)
  assert_eq(segment, "a   ")
  assert_eq(display_width(segment), 4)
}

///|
/// 基线的样式要一起拷过来：只拷字符的话下一帧会把「同字不同色」当成没变。
async test "clone_screen keeps styles but clears dirty" {
  let screen = Screen::new(2, 1)
  screen.set_styled(0, 0, "a", style_added)
  let clone = clone_screen(screen)
  assert_eq(clone.style_at(0, 0), style_added)
  assert_eq(clone.style_at(1, 0), style_default)
  assert_false(clone.dirty[0])
}

///|
/// 样式不同也算脏——这是「样式进脏格判定」的最小断言。
async test "is_dirty treats a style-only change as a change" {
  let current = Screen::new(2, 1)
  let baseline = Screen::new(2, 1)
  baseline.set(0, 0, "a")
  current.set_styled(0, 0, "a", style_added)
  assert_true(is_dirty(current, baseline, 0, 0))
  // 样式写回默认值：脏了但没变
  let same = Screen::new(2, 1)
  let same_base = Screen::new(2, 1)
  same.set_styled(1, 0, "x", style_added)
  same_base.set_styled(1, 0, "x", style_added)
  assert_false(is_dirty(same, same_base, 1, 0))
}

///|
/// 脏段里逐格切样式：段首、段中、复位三处都要有字节。
async test "segment_string switches style inside a segment" {
  let screen = Screen::new(4, 1)
  screen.write_text(0, 0, "abcd")
  screen.set_styled(0, 0, "a", style_added)
  screen.set_styled(1, 0, "b", style_added)
  screen.set_styled(2, 0, "c", style_modified)
  let segment = segment_string(screen, 0, 3, 0)
  assert_eq(segment, "\u{1b}[0m\u{1b}[92mab\u{1b}[0m\u{1b}[93mc\u{1b}[0md")
}

///|
/// 全默样式的段不插任何 SGR（绝大多数画面走这条路径）。
async test "segment_string leaves a plain segment untouched" {
  let screen = Screen::new(3, 1)
  screen.write_text(0, 0, "abc")
  assert_eq(segment_string(screen, 0, 2, 0), "abc")
}
