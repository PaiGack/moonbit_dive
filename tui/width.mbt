///|
/// 文本显示宽度的度量。
///
/// tty 只给终端原语，不给「一个字符占几列」的答案；TUI 的每个画面都要按列裁剪、
/// 按列对齐，所以这层必须自己出。
///
/// 口径是 **grapheme cluster 为最小单位**：终端里一个 ZWJ 家族 emoji
/// （`👨‍👩‍👧‍👦`）只画一个字形、占 2 列，按码点相加会算成 8 列，右侧对齐就全歪了。
/// 因此这里先划 cluster，每个 cluster 的宽度由**第一个有宽度的码点**定：
///
/// - ZWJ 连接的后续码点（`‍🚀`）在 cluster 内部，不再贡献宽度
/// - 组合记号 / 变体选择符 / tag 字符零宽，不抢先定宽
/// - 旗帜（一对区域指示符）取首个指示符的宽度 = 2
///
/// 不引 `kawaz/grapheme` / `moonbit-community/unicodewidth`：cluster 划分与宽度
/// 都自研，唯一借来的是零宽码点表（`width_tables.mbt`，表落地后不依赖对方）。
/// 引库会把「文本测量」这个本可独立验收的点绑死在别人的版本上。
pub fn display_width(text : StringView) -> Int32 {
  let mut width = 0
  for cluster in graphemes(text) {
    width += cluster_width(cluster)
  }
  width
}

///|
/// 一个 grapheme cluster 占几列：**第一个有宽度的码点**定宽。
///
/// ZWJ 之后的码点、组合记号、变体选择符、tag 字符都在同一 cluster 内，
/// 不再各自贡献宽度；全零宽的 cluster（孤立的组合记号）不占列。
fn cluster_width(cluster : StringView) -> Int32 {
  let mut width = 0
  let mut seen_base = false
  for char in cluster {
    let cw = char_width(char)
    if !seen_base {
      if cw != 0 {
        width = cw
        seen_base = true
      }
      continue
    }
    // VS16（U+FE0F）要求前面的窄字按 emoji 呈现：终端里会占两列。
    // keycap（`1` + VS16 + U+20E3）就是靠这一跳从 1 列变成 2 列。
    if char == '\u{FE0F}' && width == 1 {
      width = 2
    }
  }
  width
}

///|
/// 单个 `Char` 的显示宽度。
///
/// `Char` 是 Unicode 码点，代理对已被语言层拼好，这里不用再处理 UTF-16 的高低代理。
pub fn char_width(char : Char) -> Int32 {
  let code = char.to_int()
  if code == 0 {
    return 0
  }
  // 组合字符、变体选择符、格式控制字符：不占列
  if is_zero_width(code) {
    return 0
  }
  if is_wide(code) {
    return 2
  }
  1
}

///|
/// 把字符串切成 grapheme cluster 序列。
///
/// 划界只挑对宽度有影响的规则（UAX #29 的子集）：
///
/// - GB9：ZWJ 与后续码点同簇（`👨‍🚀` 是一个 cluster）
/// - GB9a：组合记号（Mn/Me/Cf）跟随前一个码点
/// - GB12/GB13：区域指示符（旗帜）两两成对
///
/// 不做完整 UAX #29（Indic 连写、Hangul L/V/T 的 cluster 边界等）：
/// 那些写法在当前画面上「整段一起判宽」就够，细划 cluster 只影响截断粒度。
pub fn graphemes(text : StringView) -> Iter[StringView] {
  let chars = text.to_array()
  let length = chars.length()
  let mut index = 0
  Iter::new(fn() {
    if index >= length {
      return None
    }
    let start = index
    index = cluster_end(chars, start)
    Some(StringView::from_array(chars[start:index]))
  })
}

///|
/// 旗帜的两个字母区指示符。
fn is_regional_indicator(char : Char) -> Bool {
  let code = char.to_int()
  code >= 0x1F1E6 && code <= 0x1F1FF
}

///|
/// `start` 所在 cluster 的右开边界（下一个 cluster 的起点）。
fn cluster_end(chars : Array[Char], start : Int32) -> Int32 {
  let length = chars.length()
  let mut index = start + 1
  // GB12/GB13：区域指示符两两成对，孤立的一个自成 cluster
  if is_regional_indicator(chars[start]) {
    if index < length && is_regional_indicator(chars[index]) {
      index = index + 1
    }
    return index
  }
  while index < length {
    let char = chars[index]
    // GB9 / GB11：ZWJ 与**后面的码点**同簇。这一支必须排在零宽判断前面——
    // ZWJ 自己零宽，先走零宽那支就只前进一格，emoji 序列会被拆成一堆碎片。
    if char == '\u{200D}' {
      index = min(index + 2, length)
      continue
    }
    // GB9a：组合记号、变体选择符、tag 字符永远贴在前面
    if is_zero_width(char.to_int()) {
      index = index + 1
      continue
    }
    break
  }
  index
}

///|
/// 零宽：组合记号、变体选择符、格式控制字符、tag 字符。
///
/// 查 `zero_width_ranges`（由 `scripts/gen_width_tables.py` 生成，Unicode 16.0），
/// 按区间二分。表之外的一律当有宽度——宁可多占一列，也别把真字吞掉。
fn is_zero_width(code : Int32) -> Bool {
  if code >= 0x2010 && code <= 0x206F {
    // 连字符、零宽空格、双向控制符：常用段，放在最前面省掉二分
    return code == 0x200B ||
      code == 0x200C ||
      code == 0x200D ||
      code == 0x200E ||
      code == 0x200F ||
      (code >= 0x202A && code <= 0x202E) ||
      (code >= 0x2060 && code <= 0x2064)
  }
  let mut low = 0
  let mut high = zero_width_ranges.length() - 1
  while low <= high {
    let middle = (low + high) / 2
    let (from, to) = zero_width_ranges[middle]
    if code < from {
      high = middle - 1
    } else if code > to {
      low = middle + 1
    } else {
      return true
    }
  }
  false
}

///|
/// 宽字符：东亚宽 / 全角区段、emoji 主区、区域指示符。
///
/// 只列实际会用到的区段，不做完整 EastAsianWidth 表——那份表放进来是几 KB 的常量，
/// 收益却不比这几十行多。
fn is_wide(code : Int32) -> Bool {
  if code >= 0x1100 && code <= 0x115F {
    return true
  }
  if code >= 0x2E80 && code <= 0x303E {
    return true
  }
  if code >= 0x3041 && code <= 0x33FF {
    return true
  }
  if code >= 0x3400 && code <= 0x4DBF {
    return true
  }
  if code >= 0x4E00 && code <= 0x9FFF {
    return true
  }
  if code >= 0xA000 && code <= 0xA4CF {
    return true
  }
  if code >= 0xAC00 && code <= 0xD7A3 {
    return true
  }
  if code >= 0xF900 && code <= 0xFAFF {
    return true
  }
  if code >= 0xFE30 && code <= 0xFE6F {
    return true
  }
  if code >= 0xFF00 && code <= 0xFF60 {
    return true
  }
  if code >= 0xFFE0 && code <= 0xFFE6 {
    return true
  }
  // emoji 主区（含表情、符号、交通、增补）
  if code >= 0x1F300 && code <= 0x1FAFF {
    return true
  }
  // 区域指示符：旗帜两个字母，合起来占 2 列，按首个指示符算
  if code >= 0x1F1E6 && code <= 0x1F1FF {
    return true
  }
  // 肤色修饰符：跟随基（cluster 内被跳过），单独出现时按 2 列
  if code >= 0x1F3FB && code <= 0x1F3FF {
    return true
  }
  if code >= 0x20000 && code <= 0x3FFFD {
    return true
  }
  false
}

///|
/// 生成 `count` 个空格的串；`count <= 0` 时给空串。
pub fn spaces(count : Int32) -> String {
  if count <= 0 {
    ""
  } else {
    String::make(count, ' ')
  }
}

///|
/// 按显示宽度截断，末尾 `...` 表示还有没画下的内容。
///
/// `width` 是可用列数；`<= 3` 时退化成直接截到 `width` 列（放不下省略号就只截）。
/// 切点只落在 cluster 边界上——半个 ZWJ 序列或半个组合字符画出去，
/// 终端会把它当成下一个 cluster 的头，后面的对齐会跟着漂。
/// 宽字符落到边界上会留一格空格，避免半个字被画出去把后面的对齐带歪。
pub fn truncate_to_width(text : StringView, width : Int32) -> String {
  if width <= 0 {
    return ""
  }
  if display_width(text) <= width {
    return text.to_owned()
  }
  let ellipsis = "..."
  let budget = if width > 3 { width - 3 } else { width }
  let builder = StringBuilder()
  let mut used = 0
  for cluster in graphemes(text) {
    let cw = cluster_width(cluster)
    if used + cw > budget {
      break
    }
    builder.write_string(cluster.to_owned())
    used += cw
  }
  if width > 3 {
    builder.write_string(ellipsis)
    used += 3
  }
  // 宽字符卡在边界上时 budget 会剩 1 列，用空格补齐，保证返回宽度恰好等于 width
  if used < width {
    builder.write_string(spaces(width - used))
  }
  builder.to_string()
}

///|
/// 按显示宽度左侧补齐到 `width` 列；已超宽则原样返回（裁剪由调用方决定）。
pub fn pad_to_width(text : StringView, width : Int32) -> String {
  let used = display_width(text)
  if used >= width {
    return text.to_owned()
  }
  "\{text}\{spaces(width - used)}"
}
