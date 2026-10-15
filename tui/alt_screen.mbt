///|
/// L0 全屏形态的终端生命周期：进 alternate screen、退出时还原。
///
/// 为什么单独一层：路径 A 的「退出后恢复原样」由 `with_raw_mode` 一个人兜住，
/// 全屏形态多了一条命——**屏幕内容**。alternate screen 是一个独立缓冲区，
/// 正常退出回到主屏、原来滚上去的 shell 输出原封不动；但如果中途
/// panic / Ctrl+C / 任务被取消，终端会停在那一屏，用户敲什么都不见了。
/// tty 的 `with_alt_screen` 用 `defer protect_from_cancel` 保证离开，
/// 这里在它之上再叠一层「退出前把该发的字节一次发完」，见 `teardown_commands`。
///
/// 「该发什么」抽成纯函数（`teardown_commands`），因此可以在没有真终端的情况下
/// 单测：`run_app` 里那几行只负责 `execute`。
pub(all) struct AltScreen {
  /// tty 已经进过 alternate screen
  mut entered : Bool
  /// 每次重建画布都置真后由 painter 消费的「首帧全量重画」意图
  mut needs_full_redraw : Bool
} derive(Debug)

///|
pub fn AltScreen::new() -> AltScreen {
  { entered: false, needs_full_redraw: true, }
}

///|
/// 进入全屏。重复调用幂等——`run_app` 在 resize 后仍可能再叫一次。
///
/// 拿不到终端状态时把错误抛给调用方（`command` 层折成「分析错误」），
/// 不在这里吞掉：进不去全屏却继续跑，画面会画到主屏上，比报错更糟。
pub async fn AltScreen::enter(self : AltScreen, tty : @tty.Tty) -> Unit {
  if self.entered {
    return
  }
  tty.enter_alt_screen()
  self.entered = true
  // alternate screen 是干净的一屏，上一帧的基线（主屏内容）对不上，
  // 这里不给 painter 留任何「可以增量」的错觉
  self.needs_full_redraw = true
}

///|
/// 退出全屏：归位光标、还原样式、回到主屏。
///
/// 顺序在 `teardown_commands` 里定死，幂等；没进过全屏就什么都不发
/// （比如 `enter` 自己抛了错，调用方仍会在 defer 里调它）。
pub async fn AltScreen::leave(self : AltScreen, tty : @tty.Tty) -> Unit {
  if !self.entered {
    return
  }
  self.entered = false
  tty.execute(teardown_commands())
}

///|
/// 退出全屏要下发的字节序列，按顺序：
///
/// 1. `ResetStyle`——画面上万一残留了 SGR（以后加配色时很容易漏），
///    先复位，别把颜色带进用户的 shell
/// 2. `ShowCursor`——全屏期间光标是藏的，回到主屏必须还回去
/// 3. `LeaveAltScreen`——最后一步：切换缓冲区。放最后是因为切换会清屏，
///    前面几步若还写在 alternate 里也不会被用户看见
///
/// 鼠标跟踪**不在这里**（#51）：「关掉鼠标」在 tty 里是 `Tty::disable_mouse`
/// （一串独立的模式位），不是一条 `Command`。它在 `run_app` 里与 `enable_mouse`
/// 配对 `defer`，且 `run_app` 里那个 defer 的注册顺序保证它会先跑——
/// 先关鼠标，再走本函数切缓冲区。
///
/// 纯函数，为的是能断言「退出一定包含这三件事」——
/// 缺任何一件都是「退出后终端不对劲」类 issue 的根因。
pub fn teardown_commands() -> Array[@tty.Command] {
  [
    @tty.Command::ResetStyle,
    @tty.Command::ShowCursor,
    @tty.Command::LeaveAltScreen,
  ]
}

///|
/// 进入全屏要下发的字节序列：清屏 + 藏光标。
///
/// 与 `teardown_commands` 对称：`EnterAltScreen` 排第一（缓冲区已在切换，
/// 后续的清屏作用在新缓冲区上），然后藏光标——全屏期间光标位置由 Painter
/// 安排，露出一个闪烁的光标只会晃眼。
///
/// 鼠标跟踪同样不在这一串里（#51），它由 `run_app` 的 `enable_mouse` /
/// `disable_mouse` 这一对管，理由见 `teardown_commands`。
pub fn enter_commands() -> Array[@tty.Command] {
  [
    @tty.Command::EnterAltScreen,
    @tty.Command::EraseDisplay,
    @tty.Command::HideCursor,
  ]
}

///|
pub extend AltScreen with @debug.Debug::{to_repr}
