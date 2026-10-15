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
/// 滚轮步长是个小常数：一次一屏会滑过头，一次一行搓不动。
test "mouse wheel step is small" {
  assert_eq(scroll_step(), 3)
}
