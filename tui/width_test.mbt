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

///|
/// ZWJ 家族 emoji：终端只画一个字形、占 2 列。
///
/// 按码点相加会得到 8 列（4 个 emoji + 3 个 ZWJ），文件名右侧的对齐就会整体右移。
/// 这是本次改动要钉住的第一个行为。
test "display_width counts zwj emoji as one glyph" {
  assert_eq(display_width("👨‍👩‍👧‍👦"), 2)
  assert_eq(display_width("👩‍❤️‍👨"), 2)
  assert_eq(display_width("👨‍🚀"), 2)
  assert_eq(display_width("🏳️‍🌈"), 2)
}

///|
/// 组合序列：基字 + 组合记号仍然只占基字的列数。
test "display_width keeps combining sequences at base width" {
  assert_eq(display_width("a\u{0301}"), 1)
  assert_eq(display_width("e\u{0301}\u{0323}"), 1)
  assert_eq(display_width("中\u{0301}"), 2)
}

///|
/// 旗帜：一对区域指示符合起来占 2 列，两对占 4 列。
test "display_width counts regional indicator pairs" {
  assert_eq(display_width("🇯🇵"), 2)
  assert_eq(display_width("🇯🇵🇺🇸"), 4)
  assert_eq(display_width("a🇯🇵b"), 4)
}

///|
/// tag 序列旗帜与 keycap：都在一个 cluster 内，按首个有宽度的码点（或 VS16 提升）算。
test "display_width handles tag sequences and keycaps" {
  assert_eq(display_width("🏴󠁧󠁢󠁷󠁬󠁳󠁿"), 2)
  // `1` + VS16 + U+20E3：VS16 让窄字按 emoji 呈现，占 2 列
  assert_eq(display_width("1\u{FE0F}\u{20E3}"), 2)
}

///|
/// 混排时逐 cluster 累加。
test "display_width sums clusters" {
  assert_eq(display_width("中a👨‍🚀"), 5)
  assert_eq(display_width("文件👨‍👩‍👧‍👦.tar"), 10)
}

///|
/// 截断只落在 cluster 边界上：不会把 ZWJ 序列切成半截。
test "truncate_to_width never splits a cluster" {
  let cut = truncate_to_width("👨‍👩‍👧‍👦xy", 4)
  assert_eq(display_width(cut), 4)
  // 切点之后不能只剩 ZWJ 接出的半个序列
  assert_false(cut.contains("\u{200D}x"))
  // 组合序列要么整体留下，要么整体去掉
  let cut2 = truncate_to_width("a\u{0301}bcd", 4)
  assert_eq(display_width(cut2), 4)
  assert_true(cut2.contains("a\u{0301}"))
}

///|
/// 窄预算下 ZWJ emoji 作为一个整体被裁掉，不会留下空 cluster。
test "truncate_to_width drops whole wide clusters" {
  // 预算 3 列：宽 emoji（2 列）+ "..." 放不下，直接截到 3 列
  let cut = truncate_to_width("👨‍🚀👨‍🚀", 3)
  assert_true(display_width(cut) <= 3)
}
