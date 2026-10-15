///|
/// L3 鼠标事件 → 动作（#51）。
///
/// 与 `keys.mbt` 对称：那边把 `KeyEvent` 翻成 `Action`，这边把 `MouseEvent`
/// 翻成 `MouseAction`。分开两个类型是因为鼠标多了一层**坐标**——
/// 「点了第 2 行」光有动作不够，落到哪个面板、哪一行是布局与视图的事。
///
/// 抽成纯函数是为了能测：`Tty::read_event` 要真终端，但「哪次点击 → 哪个意图」
/// 是一张查表，单测直接喂 `MouseEvent` 就行。
///
/// 非目标（issue #51）：拖拽 / 框选。tty 会把 `Drag` / `Move` 解出来，
/// 这里一律忽略——本轮只做「点」与「滚」。
pub(all) enum MouseAction {
  /// 左键按下：落在哪一行由坐标反查决定
  Select
  /// 滚轮向上 / 向下
  ScrollUp
  ScrollDown
  /// 右键：切换光标所在目录的展开状态（`dive` 里也是右键收放）
  ToggleFold
  /// `Ctrl + 左键`：切焦点（点一下树/详情，键盘就交给那块面板）
  SetFocus
  /// 没绑定的鼠标事件（拖拽、移动、中键、滚轮左右）
  None
} derive(Eq, Debug)

///|
/// 把一次鼠标事件翻成动作。
///
/// 只认 `Press(Left)` 与 `Scroll`：
///
/// - `Release` / `Drag` / `Move` 全部忽略；`Press` 已经够用，
///   再响应一次松开会让「点一下」变成两次动作
/// - `Ctrl + 左键` 走切焦点，与「点哪选哪」区分开：
///   光点击在有详情面板的屏上是「选行 + 看详情」，不该顺带把键盘焦点夺走
///
/// `MouseEvent.row` / `col` 在这里不参与判定（只做「什么动作」），
/// 落到哪一行由 `AppState::handle_mouse` 用 `Layout` + 坐标反查决定。
pub fn action_of_mouse(event : @input.MouseEvent) -> MouseAction {
  match event.kind {
    @input.MouseEventKind::Press(@input.MouseButton::Left) =>
      if event.modifiers.ctrl() {
        MouseAction::SetFocus
      } else {
        MouseAction::Select
      }
    @input.MouseEventKind::Press(@input.MouseButton::Right) =>
      MouseAction::ToggleFold
    @input.MouseEventKind::Scroll(@input.MouseScroll::Up) =>
      MouseAction::ScrollUp
    @input.MouseEventKind::Scroll(@input.MouseScroll::Down) =>
      MouseAction::ScrollDown
    // 中键、滚轮左右、拖拽与移动：本轮不接（拖拽/框选在 #51 的非目标里）
    _ => MouseAction::None
  }
}

///|
/// 滚轮一次滚几行。
///
/// 翻页键是「一整页」，滚轮给 3 行：滚轮事件密度高，一次一屏会滑过头，
/// 一次一行又得搓上十几下才挪一屏。
pub fn scroll_step() -> Int32 {
  3
}

///|
pub extend MouseAction with Eq::{equal, not_equal}

///|
pub extend MouseAction with @debug.Debug::{to_repr}
