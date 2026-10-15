///|
/// ASCII 一列一个。
test "display_width counts ascii as one column" {
  assert_eq(display_width("abc"), 3)
  assert_eq(display_width(""), 0)
}

///|
/// CJK 占两列——这是 TUI 对齐最容易错的地方，必须钉住。
test "display_width counts cjk as two columns" {
  assert_eq(display_width("中文"), 4)
  assert_eq(display_width("a中b"), 4)
}

///|
/// 组合记号不额外占列。
test "display_width ignores combining marks" {
  // a + U+0301（组合尖音符）
  assert_eq(char_width('a'), 1)
  assert_eq(char_width('\u{0301}'), 0)
  assert_eq(display_width("a\u{0301}"), 1)
}

///|
/// 截断要按列，且结果宽度不超过预算。
test "truncate_to_width respects column budget" {
  assert_eq(truncate_to_width("abcdef", 10), "abcdef")
  let cut = truncate_to_width("abcdefghij", 5)
  assert_true(display_width(cut) <= 5)
  // 末尾要有省略号
  assert_true(cut.contains("..."))
}

///|
/// 宽字符不会被截成一半：结果宽度恰好等于预算，且不含半个字。
test "truncate_to_width never splits a wide char" {
  let text = "中中中中中"
  let cut = truncate_to_width(text, 5)
  assert_eq(display_width(cut), 5)
}

///|
/// 极窄预算也要有确定行为。
test "truncate_to_width handles tiny budgets" {
  assert_eq(truncate_to_width("abc", 0), "")
  assert_eq(truncate_to_width("abc", 1), "a")
  assert_eq(truncate_to_width("abc", 2), "ab")
}

///|
/// 补齐到指定列宽。
test "pad_to_width pads with spaces" {
  assert_eq(pad_to_width("ab", 5), "ab   ")
  assert_eq(display_width(pad_to_width("中", 4)), 4)
  // 已超宽时不截断，交给调用方
  assert_eq(pad_to_width("abcdef", 3), "abcdef")
}

///|
/// `spaces` 的边界。
test "spaces handles non-positive counts" {
  assert_eq(spaces(0), "")
  assert_eq(spaces(-1), "")
  assert_eq(spaces(3), "   ")
}
