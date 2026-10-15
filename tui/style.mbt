///|
/// 画布上的样式层。
///
/// `Screen` 每格除了字符还带一份 `Style`；样式在**画的时候**跟着格子落进去，
/// 「这一帧长什么样」与「怎么把差异吐出去」两件事仍然分得开：
/// `style.mbt` 只说「一份样式对应哪些 SGR 命令」，`terminal.mbt` 负责
/// 「哪些格子要重画、脏段里怎么插复位」。
///
/// 颜色刻意不用 RGB 字面量：深色终端上 `#ff5555` 好看，浅色终端上糊成一片。
/// 用 ANSI 的 16 色槽（`BrightGreen` 之类），终端自己会把槽映射成适合
/// 当前配色的取值——深浅两种终端都读得清，这是本轮「不做主题」的前提。
///
/// `fg` / `bg` 都用 `Default`：绝大多数格子应当是终端默认色，
/// 只有 diff 的 added / modified / removed 三类上色，其余保持原样。
pub(all) struct Style {
  fg : @tty_color.Color
  bg : @tty_color.Color
  bold : Bool
} derive(Eq, Debug)

///|
/// 终端默认样式。
pub let style_default : Style = {
  fg: @tty_color.Default,
  bg: @tty_color.Default,
  bold: false,
}

///|
/// 本层新增：亮绿。
pub let style_added : Style = {
  fg: @tty_color.Basic(@tty_color.BrightGreen),
  bg: @tty_color.Default,
  bold: false,
}

///|
/// 本层改写：亮黄。
pub let style_modified : Style = {
  fg: @tty_color.Basic(@tty_color.BrightYellow),
  bg: @tty_color.Default,
  bold: false,
}

///|
/// 未变的行：暗一档，好让「这层动过的」自己跳出来。
pub let style_dim : Style = {
  fg: @tty_color.Basic(@tty_color.BrightBlack),
  bg: @tty_color.Default,
  bold: false,
}

///|
/// 删除列表里的路径：亮红，与「+ 绿 / ~ 黄」凑成一组完整的 diff 语义。
pub let style_removed : Style = {
  fg: @tty_color.Basic(@tty_color.BrightRed),
  bg: @tty_color.Default,
  bold: false,
}

///|
/// 面板标题：加粗，不换色。
pub let style_title : Style = {
  fg: @tty_color.Default,
  bg: @tty_color.Default,
  bold: true,
}

///|
/// 是不是终端默认样式（不必下发任何 SGR）。
pub fn Style::is_default(self : Style) -> Bool {
  self == style_default
}

///|
/// 一份样式要下发的 SGR 命令，按「前景 → 背景 → 加粗」的顺序。
///
/// 只发**偏离默认**的那几项：发 `Default` 前景等于发一条 `\e[39m`，
/// 每格都带着它会让增量重画的字节数翻好几倍，还会把终端里继承来的样式抹掉。
pub fn Style::commands(self : Style) -> Array[@tty.Command] {
  let commands : Array[@tty.Command] = []
  if self.fg != @tty_color.Default {
    commands.push(@tty.Command::SetForeground(self.fg))
  }
  if self.bg != @tty_color.Default {
    commands.push(@tty.Command::SetBackground(self.bg))
  }
  if self.bold {
    commands.push(@tty.Command::SetBold)
  }
  commands
}

///|
/// 下发给某格的样式串（可直接拼进 `Print`）。
///
/// 空的默认样式给空串：调用方据此判断「这段里根本没有样式切换」。
pub fn Style::sgr(self : Style) -> String {
  let builder = StringBuilder()
  if self.fg != @tty_color.Default {
    builder.write_string(color_sgr(self.fg, false))
  }
  if self.bg != @tty_color.Default {
    builder.write_string(color_sgr(self.bg, true))
  }
  if self.bold {
    builder.write_string("\u{1b}[1m")
  }
  builder.to_string()
}

///|
/// 复位所有 SGR 属性的字节序列（`\e[0m`）。
///
/// 与 `style_default` 对应：一次复位就把前景、背景、加粗全带回终端默认，
/// 不必逐项发 `\e[39m` / `\e[49m` / `\e[22m`。
pub fn sgr_reset() -> String {
  "\u{1b}[0m"
}

///|
/// 单个颜色的 SGR 序列。
///
/// 只支持 16 色槽与默认色：`Color::Rgb` / `Indexed` 是 tty 的能力，
/// 本轮不用，真要用时在这里补，别让调用方各自拼字节。
fn color_sgr(color : @tty_color.Color, background : Bool) -> String {
  match color {
    @tty_color.Default => if background { "\u{1b}[49m" } else { "\u{1b}[39m" }
    @tty_color.Basic(basic) => {
      let code = basic_color_code(basic)
      // 背景 = 前景码 + 10（ECMA-48 的老规矩，90+ 那组同样成立）
      let shifted = if background { code + 10 } else { code }
      "\u{1b}[\{shifted}m"
    }
    @tty_color.Indexed(index) =>
      if background {
        "\u{1b}[48;5;\{index}m"
      } else {
        "\u{1b}[38;5;\{index}m"
      }
    @tty_color.Rgb(red, green, blue) =>
      if background {
        "\u{1b}[48;2;\{red};\{green};\{blue}m"
      } else {
        "\u{1b}[38;2;\{red};\{green};\{blue}m"
      }
  }
}

///|
/// 16 色槽的 SGR 参数，对齐 ECMA-48 / tty 的 `basic_foreground_code`。
fn basic_color_code(color : @tty_color.BasicColor) -> Int32 {
  match color {
    @tty_color.Black => 30
    @tty_color.Red => 31
    @tty_color.Green => 32
    @tty_color.Yellow => 33
    @tty_color.Blue => 34
    @tty_color.Magenta => 35
    @tty_color.Cyan => 36
    @tty_color.White => 37
    @tty_color.BrightBlack => 90
    @tty_color.BrightRed => 91
    @tty_color.BrightGreen => 92
    @tty_color.BrightYellow => 93
    @tty_color.BrightBlue => 94
    @tty_color.BrightMagenta => 95
    @tty_color.BrightCyan => 96
    @tty_color.BrightWhite => 97
  }
}

///|
pub extend Style with Eq::{equal, not_equal}

///|
pub extend Style with @debug.Debug::{to_repr}
