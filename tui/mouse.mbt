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
  /// 左键按下：落到哪一行由坐标反查决定；落在目录行上顺带切展开态（#62）
  Select
  /// 滚轮向上 / 向下
  ScrollUp
  ScrollDown
  /// 右键：切换光标所在目录的展开状态（`dive` 里也是右键收放）
  ToggleFold
  /// `Ctrl + 左键`：切焦点（点一下树/详情，键盘就交给那块面板）；
  /// `Ctrl + 右键`：反向切（与 `Shift+Tab` 对称）
  SetFocus
  SetFocusBack
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
/// 「左键点目录行要不要顺带开合」**不在这里**判：那要知道点的是不是目录行，
/// 得先反查坐标。这里只给 `Select`，由 `AppState::handle_mouse` 落地（#62）。
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
      if event.modifiers.ctrl() {
        MouseAction::SetFocusBack
      } else {
        MouseAction::ToggleFold
      }
    @input.MouseEventKind::Scroll(@input.MouseScroll::Up) =>
      MouseAction::ScrollUp
    @input.MouseEventKind::Scroll(@input.MouseScroll::Down) =>
      MouseAction::ScrollDown
    // 中键、滚轮左右、拖拽与移动：本轮不接（拖拽/框选在 #51 的非目标里）
    _ => MouseAction::None
  }
}

///|
/// 鼠标跟踪的模式位（#62，接替 #51 的 `Click`）。
///
/// `Drag`（`?1002h`）比 `Click`（`?1000h`）多报「按住移动」那一档：
/// 点击本身两者都报，但 `1000h` 下 `cb` 里没有「拖动」这档，
/// 以后想加「拖到边框调大小」还得再改一次模式位。现在换上，代价只是
/// 终端在按住拖动时多吐几个事件——`action_of_mouse` 一律忽略 `Drag`。
///
/// 开了 kitty 像素鼠标协议的终端上退到 `Motion`（`?1003h`）：
/// 「像素坐标」那一套要 any-event 跟踪才说话，沿用 `1002h` 收不到。
pub fn mouse_tracking_mode(pixel_mouse~ : Bool) -> @tty.MouseTrackingMode {
  if pixel_mouse {
    @tty.MouseTrackingMode::Motion
  } else {
    @tty.MouseTrackingMode::Drag
  }
}

///|
/// 鼠标跟踪的模式位（#62，接替 #51 的 `Click`）。
///
/// 为什么要这一层：tty 0.5.0 的 `CSI <` 只认 `cb ; col ; row M/m`；
/// kitty 的鼠标协议会多带一块鼠标信息（`code ; x ; y ; d`），
/// tty 直接判 `Unknown`，事件在主循环里**静默消失**——表现是「点哪都没反应」，
/// 比「点不开目录」还重一档。把坐标换算回格子，至少让点击落在正确位置。
///
/// `viewport_cols` / `viewport_rows` 是终端**实际**的格子数。
/// 终端报上来的坐标若是像素，值会远超格子数；这时按「像素 ÷ 每格像素」换算
/// ——每格像素从「像素坐标 ÷ 格子数」反推，换算完夹回格子范围，
/// 不让一次点击落到屏幕外。
///
/// 判定为「格子口径」时原样返回：普通终端（xterm SGR `CSI <` 不带子参数）
/// 走的都是这条路，一个字节都不动。
pub fn resolve_mouse(
  event : @input.MouseEvent,
  viewport_cols : Int32,
  viewport_rows : Int32,
) -> @input.MouseEvent {
  let (row, col) = (event.row, event.col)
  if viewport_cols <= 0 || viewport_rows <= 0 {
    return event
  }
  // 格子口径的坐标不可能超过格子数；超了就说明报的是像素
  if col <= viewport_cols && row <= viewport_rows {
    return event
  }
  let cell_width = max(col / viewport_cols, 1)
  let cell_height = max(row / viewport_rows, 1)
  @input.MouseEvent::new(
    event.kind,
    clamp(pixel_to_cell(row, cell_height), 1, viewport_rows),
    clamp(pixel_to_cell(col, cell_width), 1, viewport_cols),
    modifiers=event.modifiers,
  )
}

///|
/// 像素值 → 格子序号（1 起）：先减一格再整除，最后补 1。
///
/// 顺序关键：像素 `p` 落在第 `floor((p - 1) / size) + 1` 格，
/// 直接写 `(p + size - 1) / size` 在 `size` 小的时候会被整除进一档
/// （`p = 51`、`size = 2` 时会算成 26，而不是 25）。
/// 单测里成对断言过这条路，别再把两种写法混起来。
fn pixel_to_cell(pixel : Int32, cell_size : Int32) -> Int32 {
  (pixel - 1) / cell_size + 1
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
