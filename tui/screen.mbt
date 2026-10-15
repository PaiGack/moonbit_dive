///|
/// 一块按「列 × 行」组织的字符画布。
///
/// tty 只管往终端吐字节，不给屏幕模型；TUI 的每帧都先画在这块缓冲上，
/// 再和上一帧逐格比对、只吐变化的格子——不然每帧全量重画会闪。
///
/// 一格存的是**字符串**而不是单个 `Char`：一个 grapheme cluster 可能是多码点
/// （`👨‍🚀` 是 4 个码点），按 Char 存会把 ZWJ 与后半段丢掉，重画时只剩一个 `👨`。
/// 零宽成员（ZWJ / 变体选择符 / 组合记号）拼进首格，不额外占列。
///
/// 每格还带一份 `Style`（前景 / 背景 / 加粗）。样式与字符同属「这一帧的样子」，
/// 因此它们的**比较**在 `terminal.mbt` 里一起参与脏格判定：
/// 字符没变、只改了颜色，同样要重画（issue #53 的验收之一）。
pub(all) struct Screen {
  cols : Int32
  rows : Int32
  /// 每格的内容；空格表示空白，空串表示宽字符抢占的占位格
  cells : Array[String]
  /// 每格的样式；与 `cells` 一一对应
  styles : Array[Style]
  dirty : Array[Bool]
} derive(Debug)

///|
pub fn Screen::new(cols : Int32, rows : Int32) -> Screen {
  let cols = if cols > 0 { cols } else { 1 }
  let rows = if rows > 0 { rows } else { 1 }
  let cells = Array::make(cols * rows, " ")
  let styles = Array::make(cols * rows, style_default)
  let dirty = Array::make(cols * rows, false)
  { cols, rows, cells, styles, dirty, }
}

///|
/// 画布尺寸；与当前尺寸相同就原样返回，避免 resize 时无谓重建。
pub fn Screen::resize(self : Screen, cols : Int32, rows : Int32) -> Screen {
  let cols = if cols > 0 { cols } else { 1 }
  let rows = if rows > 0 { rows } else { 1 }
  if cols == self.cols && rows == self.rows {
    return self
  }
  Screen::new(cols, rows)
}

///|
/// 写一格，样式保持当前值；越界直接丢掉（组件不必自己算边界）。
pub fn Screen::set(
  self : Screen,
  col : Int32,
  row : Int32,
  text : StringView,
) -> Unit {
  self.set_styled(col, row, text, self.style_at(col, row))
}

///|
/// 写一格并带上样式。
///
/// 同一格在同一帧里被写第二次（后画的盖住先画的）时，样式跟着走，
/// 不会留下上一笔的颜色——`clear_pane` 之后再写正文就靠这个。
pub fn Screen::set_styled(
  self : Screen,
  col : Int32,
  row : Int32,
  text : StringView,
  style : Style,
) -> Unit {
  if col < 0 || col >= self.cols || row < 0 || row >= self.rows {
    return
  }
  let index = row * self.cols + col
  self.cells[index] = text.to_owned()
  self.styles[index] = style
  self.dirty[index] = true
}

///|
/// 读一格；越界给空格。
pub fn Screen::get(self : Screen, col : Int32, row : Int32) -> String {
  if col < 0 || col >= self.cols || row < 0 || row >= self.rows {
    return " "
  }
  self.cells[row * self.cols + col]
}

///|
/// 读一格的样式；越界给默认样式。
pub fn Screen::style_at(self : Screen, col : Int32, row : Int32) -> Style {
  if col < 0 || col >= self.cols || row < 0 || row >= self.rows {
    return style_default
  }
  self.styles[row * self.cols + col]
}

///|
/// 在某行写一段文本，超出右边界的内容**按列**裁掉。
///
/// 切点按 cluster：`👨‍🚀` 落不进剩余列数时整簇丢掉，不会把 ZWJ 序列切成半个。
/// 宽字符（占 2 列）落在最后一列时写成空格：宁可少画一个字，
/// 也不让终端把行宽撑出去、把后面的内容挤到下一行。
pub fn Screen::write_text(
  self : Screen,
  col : Int32,
  row : Int32,
  text : StringView,
) -> Unit {
  self.write_styled(col, row, text, style_default)
}

///|
/// 带样式地写一段文本；规则与 `write_text` 一致。
///
/// 窄屏上宽字符写不下时补的那个空格也带样式（背景延续到行尾，看起来才是一整块）。
pub fn Screen::write_styled(
  self : Screen,
  col : Int32,
  row : Int32,
  text : StringView,
  style : Style,
) -> Unit {
  let mut x = col
  for cluster in graphemes(text) {
    if x >= self.cols {
      break
    }
    let width = display_width(cluster)
    if width == 0 {
      continue
    }
    if x + width > self.cols {
      self.set_styled(x, row, " ", style)
      break
    }
    self.set_styled(x, row, cluster, style)
    if width == 2 {
      // 宽字符的后半格标记为已占位，但不重复写内容
      self.set_styled(x + 1, row, "", style)
    }
    x += width
  }
}

///|
/// 整行填满空格（样式回默认，别把上一帧的颜色留在空处）。
pub fn Screen::clear_row(self : Screen, row : Int32) -> Unit {
  for col = 0; col < self.cols; col = col + 1 {
    self.set_styled(col, row, " ", style_default)
  }
}

///|
/// 全屏清空（清掉的格子都进脏集，下一帧会重画）。
pub fn Screen::clear(self : Screen) -> Unit {
  for row = 0; row < self.rows; row = row + 1 {
    self.clear_row(row)
  }
}

///|
/// 把一行拼成可下发的字符串。
///
/// 宽字符写下的后半格是空串占位，终端已经由前一个宽字符推进了光标，
/// 这里不能吐内容出去（吐了会把行宽撑出去），直接跳过。
/// 样式不在这里拼：全量重画由 `terminal.mbt` 逐格插 SGR。
pub fn Screen::row_string(self : Screen, row : Int32) -> String {
  let builder = StringBuilder()
  for col = 0; col < self.cols; col = col + 1 {
    builder.write_string(self.cells[row * self.cols + col])
  }
  builder.to_string()
}

///|
pub extend Screen with @debug.Debug::{to_repr}
