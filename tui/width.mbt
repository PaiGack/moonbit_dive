///|
/// 文本显示宽度的度量。
///
/// tty 只给终端原语，不给「一个字符占几列」的答案；TUI 的每个画面都要按列裁剪、
/// 按列对齐，所以这层必须自己出。
///
/// 口径按 wcwidth 的常用近似：
///
/// - 组合字符（零宽）：不占列
/// - 东亚宽 / 全角 / emoji 一类：占 2 列
/// - 其余可见字符：占 1 列
///
/// 不引 `kawaz/grapheme` 或 `unicodewidth`：本轮的画面对 ASCII + 常见 CJK 足够，
/// 引第三方库会把「文本测量」这个本可以独立验收的点绑死在别人的版本上。
/// 真要做 grapheme cluster（ZWJ emoji 序列）再单开 issue 换实现，
/// 接口就这一个函数，换起来不牵动画面代码。
pub fn display_width(text : StringView) -> Int32 {
  let mut width = 0
  for char in text {
    width += char_width(char)
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
  // 组合字符（Mn/Me）与零宽字符：不占列
  if is_zero_width(code) {
    return 0
  }
  if is_wide(code) {
    return 2
  }
  1
}

///|
/// 零宽：组合记号、零宽空格 / 连接符、变体选择符。
fn is_zero_width(code : Int32) -> Bool {
  (code >= 0x0300 && code <= 0x036F) ||
  (code >= 0x1AB0 && code <= 0x1AFF) ||
  (code >= 0x1DC0 && code <= 0x1DFF) ||
  (code >= 0x20D0 && code <= 0x20FF) ||
  (code >= 0xFE00 && code <= 0xFE0F) ||
  (code >= 0xFE20 && code <= 0xFE2F) ||
  code == 0x200B ||
  code == 0x200C ||
  code == 0x200D ||
  code == 0xFEFF
}

///|
/// 宽字符：东亚宽 / 全角区段与 emoji 主区。
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
  if code >= 0x1F300 && code <= 0x1F64F {
    return true
  }
  if code >= 0x1F900 && code <= 0x1F9FF {
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
  for char in text {
    let cw = char_width(char)
    if used + cw > budget {
      break
    }
    builder.write_char(char)
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
