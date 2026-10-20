///|
/// 默认样式不下发任何 SGR：每格都带一条 `\e[39m` 会让增量重画的字节数翻倍。
async test "default style emits no sgr" {
  assert_true(style_default.is_default())
  assert_eq(style_default.sgr(), "")
  assert_eq(style_default.commands().length(), 0)
}

///|
/// 16 色槽翻译成前景 / 背景两个方向：背景码 = 前景码 + 10。
async test "basic colors map to foreground and background sgr" {
  assert_eq(style_added.sgr(), "\u{1b}[92m")
  assert_eq(style_modified.sgr(), "\u{1b}[93m")
  // 亮黑做前景是 90，做背景是 100
  let on_black : Style = {
    fg: @tty_color.Default,
    bg: @tty_color.Basic(@tty_color.Black),
    bold: false,
  }
  assert_eq(on_black.sgr(), "\u{1b}[40m")
}

///|
/// 加粗与颜色可以叠在一起，复位是一条 `\e[0m` 收尾。
async test "style sgr combines color and bold" {
  let style : Style = {
    fg: @tty_color.Basic(@tty_color.Red),
    bg: @tty_color.Default,
    bold: true,
  }
  assert_eq(style.sgr(), "\u{1b}[31m\u{1b}[1m")
  assert_eq(sgr_reset(), "\u{1b}[0m")
}

///|
/// `commands()` 给的是 tty 命令，与 `sgr()` 的文字是同一种意思。
async test "style commands use tty color commands" {
  let commands = style_added.commands()
  assert_eq(commands.length(), 1)
  assert_true(
    commands[0]
    is @tty.Command::SetForeground(@tty_color.Basic(@tty_color.BrightGreen)),
  )
}
