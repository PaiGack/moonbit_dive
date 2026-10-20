///|
/// 各分支都要走到，否则 0 宽 / 宽字符 / 普通字符的分类回归时看不出来。
async test "char_width classifies control, wide and normal" {
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
async test "display_width sums per-char widths" {
  assert_eq(display_width(""), 0)
  assert_eq(display_width("abc"), 3)
  assert_eq(display_width("中a"), 3)
  assert_eq(display_width("中中"), 4)
}

///|
/// cluster 划分：ZWJ 序列、组合记号、旗帜、普通字各自成簇。
async test "graphemes splits zwj sequences and flags" {
  assert_eq(graphemes("👨‍👩‍👧‍👦").count(), 1)
  assert_eq(graphemes("👨‍🚀👩‍🚀").count(), 2)
  assert_eq(graphemes("a\u{0301}b").count(), 2)
  assert_eq(graphemes("🇯🇵🇺🇸x").count(), 3)
  assert_eq(graphemes("").count(), 0)
}

///|
/// 单个 cluster 的宽度口径。
async test "cluster_width picks the first visible codepoint" {
  assert_eq(cluster_width("👨‍🚀"), 2)
  assert_eq(cluster_width("a\u{0301}"), 1)
  assert_eq(cluster_width("\u{0301}"), 0)
  assert_eq(cluster_width("1\u{FE0F}\u{20E3}"), 2)
}
