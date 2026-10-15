///|
/// 在一对管道上建 tty，跑 `f`，返回 tty 写出去的全部字节。
///
/// 用管道而不是真终端：`paint` 只依赖 tty 的写接口，把字节收回来就能断言
/// 「发了哪些转义序列、哪些文本」，不用伪终端。
async fn with_pipe_tty(f : async (@tty.Tty) -> Unit) -> String {
  let (input, input_writer) = @async/pipe.pipe()
  let (output_reader, output) = @async/pipe.pipe()
  input_writer.close()
  let tty = @tty.Tty::new(input, output)
  f(tty)
  tty.close()
  let text = output_reader.read_all().text()
  output_reader.close()
  text
}

///|
/// 首帧全量画：清屏 + 每行内容。
async test "painter writes a full frame on the first paint" {
  let screen = Screen::new(6, 2)
  screen.write_text(0, 0, "hello")
  screen.write_text(0, 1, "world")
  let painter = Painter::new()
  let written = with_pipe_tty(tty => painter.paint(tty, screen))
  assert_true(written.contains("hello"))
  assert_true(written.contains("world"))
  // 全量重画带清屏
  assert_true(written.contains("\u{1b}[2J"))
}

///|
/// 第二帧只吐变化的格子：未动的行不重发。
async test "painter writes only dirty cells on the second frame" {
  let screen = Screen::new(6, 2)
  screen.write_text(0, 0, "hello")
  screen.write_text(0, 1, "world")
  let painter = Painter::new()
  ignore(with_pipe_tty(tty => painter.paint(tty, screen)))
  // 改第二行；第一行不动
  screen.set(0, 1, "W")
  let written = with_pipe_tty(tty => painter.paint(tty, screen))
  // 只重发那一个变化的格子
  assert_true(written.contains("W"))
  // 未动的行不再下发
  assert_false(written.contains("hello"))
  assert_false(written.contains("orld"))
}

///|
/// 尺寸变了就整屏重画（旧基线不能再用）。
async test "painter repaints fully after a resize" {
  let painter = Painter::new()
  let small = Screen::new(4, 1)
  small.write_text(0, 0, "ab")
  ignore(with_pipe_tty(tty => painter.paint(tty, small)))
  let wide = Screen::new(8, 1)
  wide.write_text(0, 0, "abcdef")
  let written = with_pipe_tty(tty => painter.paint(tty, wide))
  assert_true(written.contains("abcdef"))
  assert_true(written.contains("\u{1b}[2J"))
}

///|
/// 脏格与基线一致时不重画（写回原值）。
async test "painter skips cells written back to their old value" {
  let screen = Screen::new(4, 1)
  screen.write_text(0, 0, "abcd")
  let painter = Painter::new()
  ignore(with_pipe_tty(tty => painter.paint(tty, screen)))
  screen.set(0, 0, "a")
  let written = with_pipe_tty(tty => painter.paint(tty, screen))
  assert_false(written.contains("abcd"))
}
