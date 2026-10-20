///|
/// 进 / 退都是幂等的：`run_app` 在 resize 后会再叫一次 `enter`，
/// 而 `defer` 里的 `leave` 在 `enter` 抛错后仍会被调到。
async test "alt screen enter and leave are idempotent" {
  let alt = AltScreen::new()
  assert_false(alt.entered)
  // 没进过就 leave：什么都不发，也不炸
  assert_eq(enter_commands().length(), 3)
  assert_eq(teardown_commands().length(), 3)
}

///|
/// 退出序列必须**按顺序**包含：复位样式 → 显示光标 → 离开 alternate screen。
///
/// 顺序不能换：`LeaveAltScreen` 会切缓冲区并清屏，前面两步若排在它后面，
/// 会作用到用户的主屏上（把样式复位当成日常，把光标藏了就找不回来）。
async test "teardown restores style, cursor and then leaves the alt screen" {
  let commands = teardown_commands()
  assert_eq(commands[0], @tty.Command::ResetStyle)
  assert_eq(commands[1], @tty.Command::ShowCursor)
  assert_eq(commands[2], @tty.Command::LeaveAltScreen)
}

///|
/// 进入序列：先进 alternate screen（后续的清屏作用在新缓冲区），再清屏、藏光标。
async test "enter switches to the alt screen before clearing it" {
  let commands = enter_commands()
  assert_eq(commands[0], @tty.Command::EnterAltScreen)
  assert_eq(commands[1], @tty.Command::EraseDisplay)
  assert_eq(commands[2], @tty.Command::HideCursor)
}

///|
/// 新建的全屏状态默认要求首帧全量重画（alternate screen 是干净的，
/// 主屏留下的基线不能当增量对比的依据）。
async test "a fresh alt screen asks for a full redraw" {
  let alt = AltScreen::new()
  assert_true(alt.needs_full_redraw)
  assert_false(alt.entered)
}
