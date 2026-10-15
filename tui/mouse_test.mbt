///|
/// 造一个鼠标事件。
fn mouse(
  kind : @input.MouseEventKind,
  row~ : Int32 = 1,
  col~ : Int32 = 1,
  ctrl~ : Bool = false,
) -> @input.MouseEvent {
  @input.MouseEvent::new(
    kind,
    row,
    col,
    modifiers=@input.KeyModifiers::new(ctrl~),
  )
}

///|
/// 左键按下是选中，Ctrl + 左键是切焦点。
test "mouse press maps to select or focus" {
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Press(@input.MouseButton::Left)),
    ),
    MouseAction::Select,
  )
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Press(@input.MouseButton::Left), ctrl=true),
    ),
    MouseAction::SetFocus,
  )
}

///|
/// 滚轮上下各走一步；左右滚轮本轮不接。
test "mouse wheel maps to scrolling" {
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Scroll(@input.MouseScroll::Up)),
    ),
    MouseAction::ScrollUp,
  )
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Scroll(@input.MouseScroll::Down)),
    ),
    MouseAction::ScrollDown,
  )
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Scroll(@input.MouseScroll::Left)),
    ),
    MouseAction::None,
  )
}

///|
/// 拖拽 / 移动 / 松开全部忽略：本轮不做拖拽与框选（#51 非目标）。
test "mouse drag and release are ignored" {
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Drag(@input.MouseButton::Left)),
    ),
    MouseAction::None,
  )
  assert_eq(
    action_of_mouse(mouse(@input.MouseEventKind::Move)),
    MouseAction::None,
  )
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Release(@input.MouseButton::Left)),
    ),
    MouseAction::None,
  )
  // 中键没有落点，也不接
  assert_eq(
    action_of_mouse(
      mouse(@input.MouseEventKind::Press(@input.MouseButton::Middle)),
    ),
    MouseAction::None,
  )
}

///|
/// 鼠标跟踪模式位（#62）：默认 `Drag`（比 #51 的 `Click` 多一档「按住移动」），
/// 像素鼠标终端上退到 `Motion`。
test "mouse tracking mode is drag by default and motion for pixel reports" {
  assert_eq(
    mouse_tracking_mode(pixel_mouse=false),
    @tty.MouseTrackingMode::Drag,
  )
  assert_eq(
    mouse_tracking_mode(pixel_mouse=true),
    @tty.MouseTrackingMode::Motion,
  )
}

///|
/// 像素口径的坐标换算回格子（#62）。
///
/// 1600x1200 像素 / 80x24 格 → 每格 20x50 像素。
test "pixel mouse coordinates are converted back to cells" {
  // 像素 (col 1030, row 51)：每格 12x2（从 1030/80、51/24 反推）
  // 换算成格子是第 24 行、第 80 列（夹在边界上）
  let event = resolve_mouse(
    mouse(
      @input.MouseEventKind::Press(@input.MouseButton::Left),
      row=51,
      col=1030,
    ),
    80,
    24,
  )
  assert_eq(event.row, 24)
  assert_eq(event.col, 80)
  // 按键与修饰符照原样带过来
  assert_eq(event.kind, @input.MouseEventKind::Press(@input.MouseButton::Left))
}

///|
/// 换算后的落点落在视口内，不会因为四舍五入跑出去。
///
/// `resolve_mouse` 的每格像素是**从报上来的坐标反推**的（`col / viewport_cols`），
/// 不是终端真报的格子尺寸；反推出来偏小的时候，换算结果会贴到视口边界，
/// 这时夹回边界内——宁可落点偏一点，也不能点到屏幕外。
test "pixel conversion stays inside the viewport" {
  let event = resolve_mouse(
    mouse(
      @input.MouseEventKind::Press(@input.MouseButton::Left),
      row=150,
      col=430,
    ),
    80,
    24,
  )
  assert_eq(event.row, 24)
  assert_eq(event.col, 80)
}

///|
/// 格子口径的坐标原样返回（普通终端走这条路，一个字节都不动）。
test "cell coordinates pass through untouched" {
  let event = resolve_mouse(
    mouse(
      @input.MouseEventKind::Press(@input.MouseButton::Right),
      row=5,
      col=60,
    ),
    80,
    24,
  )
  assert_eq(event.row, 5)
  assert_eq(event.col, 60)
  assert_eq(event.kind, @input.MouseEventKind::Press(@input.MouseButton::Right))
}

///|
/// 换算不会把点推到屏幕外：像素坐标比「格子数 × 每格像素」大时夹到边上。
test "pixel conversion clamps to the viewport" {
  let event = resolve_mouse(
    mouse(
      @input.MouseEventKind::Press(@input.MouseButton::Left),
      row=9999,
      col=9999,
    ),
    80,
    24,
  )
  assert_eq(event.row, 24)
  assert_eq(event.col, 80)
}

///|
/// 滚轮步长是个小常数：一次一屏会滑过头，一次一行搓不动。
test "mouse wheel step is small" {
  assert_eq(scroll_step(), 3)
}
