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
/// 这里刻意**不做**样式（前景/背景/加粗）：本轮画面用不到，带上它会让
/// 「缓冲 diff」和「SGR 序列拼接」两件事缠在一起。真要用色再单开一层。
pub(all) struct Screen {
  cols : Int32
  rows : Int32
  /// 每格的内容；空格表示空白，空串表示宽字符抢占的占位格
  cells : Array[String]
  dirty : Array[Bool]
} derive(Debug)

///|
pub fn Screen::new(cols : Int32, rows : Int32) -> Screen {
  let cols = if cols > 0 { cols } else { 1 }
  let rows = if rows > 0 { rows } else { 1 }
  let cells = Array::make(cols * rows, " ")
  let dirty = Array::make(cols * rows, false)
  { cols, rows, cells, dirty, }
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
/// 写一格；越界直接丢掉（组件不必自己算边界）。
pub fn Screen::set(
  self : Screen,
  col : Int32,
  row : Int32,
  text : StringView,
) -> Unit {
  if col < 0 || col >= self.cols || row < 0 || row >= self.rows {
    return
  }
  let index = row * self.cols + col
  self.cells[index] = text.to_owned()
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
      self.set(x, row, " ")
      break
    }
    self.set(x, row, cluster)
    if width == 2 {
      // 宽字符的后半格标记为已占位，但不重复写内容
      self.set(x + 1, row, "")
    }
    x += width
  }
}

///|
/// 整行填满空格。
pub fn Screen::clear_row(self : Screen, row : Int32) -> Unit {
  for col = 0; col < self.cols; col = col + 1 {
    self.set(col, row, " ")
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
pub fn Screen::row_string(self : Screen, row : Int32) -> String {
  let builder = StringBuilder()
  for col = 0; col < self.cols; col = col + 1 {
    builder.write_string(self.cells[row * self.cols + col])
  }
  builder.to_string()
}

///|
pub extend Screen with @debug.Debug::{to_repr}
