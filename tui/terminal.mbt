///|
/// 把画布变成终端字节流的一层。
///
/// 与 `Screen` 的分工：`Screen` 负责「这一帧长什么样」，这里负责「怎么把差异吐出去」。
/// 首帧（或 resize 后）按需重画整屏，之后的帧只动脏格子——
/// 全量重画在慢终端上会肉眼可见地闪。
///
/// 输出走 tty 的 `Command`，不手拼 ANSI 转义：转义序列的坑（末尾是否复位、
/// 半角/全角光标推进）由 tty 兜住，这边只管坐标。
///
/// 每帧末尾依赖 `with_synchronized_update` 把这一批字节一次性提交，
/// 避免终端边收边画导致的撕裂。
pub(all) struct Painter {
  /// 上一帧的画布；`None` 表示还没有可对比的基线（下一帧全量重画）
  mut previous : Screen?
  /// 一个格子都没写过时不必下发任何字节
  mut painted : Bool
} derive(Debug)

///|
pub fn Painter::new() -> Painter {
  { previous: None, painted: false, }
}

///|
/// 画一帧。
///
/// 有基线时逐格比对：只把变化的格子按「定位光标 → 写字」下发，连续变化的格子
/// 合并成一段（同一行的脏格子拼成一个字符串，省掉重复的定位序列）。
/// 没有基线（首帧 / resize）或尺寸变了就整屏重画。
pub async fn Painter::paint(
  self : Painter,
  tty : @tty.Tty,
  screen : Screen,
) -> Unit {
  let full_redraw = match self.previous {
    None => true
    Some(previous) =>
      previous.cols != screen.cols || previous.rows != screen.rows
  }
  if full_redraw {
    paint_full(tty, screen)
  } else {
    paint_diff(tty, self.previous.unwrap(), screen)
  }
  self.previous = Some(clone_screen(screen))
  self.painted = true
}

///|
/// 整屏重画：清屏 → 逐行输出。
///
/// 行尾不补空格的逻辑交给终端（写满一行的最后一个字符后终端会自己换行），
/// 这里对每行都输出 `cols` 个字符后换行，保证光标落在下一行行首。
async fn paint_full(tty : @tty.Tty, screen : Screen) -> Unit {
  tty.erase_display()
  let buffer = StringBuilder()
  for row = 0; row < screen.rows; row = row + 1 {
    buffer.write_string(screen.row_string(row))
    if row + 1 < screen.rows {
      buffer.write_string("\r\n")
    }
  }
  tty.write_string(buffer.to_string())
  tty.set_cursor_position(1, 1)
}

///|
/// 增量重画：只动脏格子。
///
/// `dirty` 是画布自带的位图（`Screen::set` 时置位），基线里已经一致的格子不会被标记，
/// 所以这里不用再逐格比字符，只按位图找连续段。
async fn paint_diff(tty : @tty.Tty, previous : Screen, screen : Screen) -> Unit {
  let commands : Array[@tty.Command] = []
  for row = 0; row < screen.rows; row = row + 1 {
    let mut col = 0
    while col < screen.cols {
      if !is_dirty(screen, previous, col, row) {
        col = col + 1
        continue
      }
      // 找连续脏段的右端
      let start = col
      while col < screen.cols && is_dirty(screen, previous, col, row) {
        col = col + 1
      }
      let segment = segment_string(screen, start, col - 1, row)
      // 终端坐标从 1 起
      commands.push(@tty.Command::CursorPosition(row + 1, start + 1))
      commands.push(@tty.Command::Print(segment))
    }
  }
  if !commands.is_empty() {
    tty.execute(commands)
  }
}

///|
/// 该格是否需要重画：本帧写过（dirty）**且**与基线不同。
///
/// 单看 dirty 不够：同一格先写 A 再写回原值，脏了但没变，重画纯属浪费。
fn is_dirty(
  screen : Screen,
  previous : Screen,
  col : Int32,
  row : Int32,
) -> Bool {
  let index = row * screen.cols + col
  if !screen.dirty[index] {
    return false
  }
  if col >= previous.cols || row >= previous.rows {
    return true
  }
  screen.cells[index] != previous.cells[row * previous.cols + col]
}

///|
/// 取某行 `[start, end]`（闭区间）的格子拼成串，占位格与行尾空格一并去掉。
fn segment_string(
  screen : Screen,
  start : Int32,
  end : Int32,
  row : Int32,
) -> String {
  let builder = StringBuilder()
  for col = start; col <= end; col = col + 1 {
    builder.write_string(screen.cells[row * screen.cols + col])
  }
  // 未写过的格子是空格，照常吐出去：宽度正好等于区间列数，
  // 终端光标按列推进，后面内容不会左移
  builder.to_string()
}

///|
/// 拷一份画布，作为下一帧的对比基线。
///
/// 新基线不带脏标记：基线只用来比字符，`dirty` 属于「这一帧写过什么」，
/// 拷过去会让下一帧把这一帧的脏格全部重画。
fn clone_screen(screen : Screen) -> Screen {
  let cells = Array::make(screen.cols * screen.rows, " ")
  for index = 0; index < screen.cells.length(); index = index + 1 {
    cells[index] = screen.cells[index]
  }
  {
    cols: screen.cols,
    rows: screen.rows,
    cells,
    dirty: Array::make(screen.cols * screen.rows, false),
  }
}

///|
pub extend Painter with @debug.Debug::{to_repr}
