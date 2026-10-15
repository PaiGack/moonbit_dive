///|
/// 造一块带框面板，坐标固定在 10x6 的屏幕里。
fn pane_fixture(focused~ : Bool = false) -> (Screen, Pane) {
  let screen = Screen::new(10, 6)
  let pane : Pane = {
    id: PaneId::Tree,
    rect: { left: 0, top: 0, right: 9, bottom: 5, },
    bordered: true,
    title: "files",
    focusable: true,
  }
  let _ = focused
  (screen, pane)
}

///|
/// 边框四角是 `+`、横边 `-`、竖边 `|`。
test "paint_pane draws a box around the pane" {
  let (screen, pane) = pane_fixture()
  paint_pane(screen, pane, false)
  assert_eq(screen.get(0, 0), "+")
  assert_eq(screen.get(9, 0), "+")
  assert_eq(screen.get(0, 5), "+")
  assert_eq(screen.get(9, 5), "+")
  // 顶边：`+- files +`——标题从第 3 列起，占住中间的横线
  assert_eq(screen.get(1, 0), "-")
  assert_eq(screen.get(2, 0), " ")
  assert_eq(screen.get(8, 0), " ")
  assert_eq(screen.get(0, 3), "|")
  assert_eq(screen.get(9, 3), "|")
}

///|
/// 标题画在顶边上；聚焦时前面多一个 `>`。
test "paint_pane marks the focused pane in its title" {
  let (screen, pane) = pane_fixture()
  paint_pane(screen, pane, false)
  let plain = screen.row_string(0)
  assert_true(plain.contains("files"))
  assert_false(plain.contains(">files"))
  let (focused_screen, focused_pane) = pane_fixture(focused=true)
  paint_pane(focused_screen, focused_pane, true)
  assert_true(focused_screen.row_string(0).contains(">files"))
}

///|
/// 内容区不被边框覆盖：清空只动内圈。
test "clear_pane keeps the border intact" {
  let (screen, pane) = pane_fixture()
  paint_pane(screen, pane, false)
  screen.set(4, 3, "x")
  clear_pane(screen, pane)
  assert_eq(screen.get(4, 3), " ")
  assert_eq(screen.get(0, 0), "+")
  assert_eq(screen.get(0, 3), "|")
}

///|
/// 退化到 1 列 / 1 行时不画框（画出来只剩一条线，比不画更难看）。
test "paint_pane skips boxes that cannot hold a border" {
  let screen = Screen::new(1, 1)
  let pane : Pane = {
    id: PaneId::Popup,
    rect: { left: 0, top: 0, right: 0, bottom: 0, },
    bordered: true,
    title: "x",
    focusable: false,
  }
  paint_pane(screen, pane, false)
  assert_eq(screen.row_string(0), " ")
}

///|
/// 行数提示只在内容超出窗口时出现，落在右下角。
test "paint_overflow_hint shows how much was cut" {
  let (screen, pane) = pane_fixture()
  paint_pane(screen, pane, false)
  paint_overflow_hint(screen, pane, 4, 4)
  assert_false(screen.row_string(4).contains("4/4"))
  paint_overflow_hint(screen, pane, 4, 20)
  assert_true(screen.row_string(4).contains("4/20"))
}
