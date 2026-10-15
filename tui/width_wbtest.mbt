///|
/// 各分支都要走到，否则 0 宽 / 宽字符 / 普通字符的分类回归时看不出来。
test "char_width classifies control, wide and normal" {
  // NUL 算零宽
  assert_eq(char_width('\u{0}'), 0)
  // 组合记号零宽
  assert_eq(char_width('\u{0301}'), 0)
  assert_eq(char_width('\u{200D}'), 0)
  // 东亚宽：CJK / 全角 / 韩文
  assert_eq(char_width('中'), 2)
  assert_eq(char_width('Ａ'), 2)
  assert_eq(char_width('가'), 2)
  // 常见 ASCII 与拉丁扩展一列
  assert_eq(char_width('a'), 1)
  assert_eq(char_width('é'), 1)
}

///|
/// `display_width` 把各字符的宽度加起来。
test "display_width sums per-char widths" {
  assert_eq(display_width(""), 0)
  assert_eq(display_width("abc"), 3)
  assert_eq(display_width("中a"), 3)
  assert_eq(display_width("中中"), 4)
}
