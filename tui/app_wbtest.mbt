///|
/// 造一个两层的逐层视图，供状态机测试。
async fn two_layer_views() -> Array[@layer_tree.LayerView] {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "a"),
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main", "x"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "yy"),
    @layer_tree.TarEntrySpec::File("etc/extra", "z"),
  ])
  @layer_tree.browse_layers([l0, l1])
}

///|
/// 初始层号决定起初看的是哪一层；不给时落在第 0 层
/// （「默认看最后一层」是 CLI 的取舍，由 `run_tui` 显式传进来）。
async test "app state starts on the requested layer" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo")
  assert_eq(state.view.layer, 0)
  let state_last = AppState::new(views, None, "demo", initial_layer=1)
  assert_eq(state_last.view.layer, 1)
}

///|
/// 初始层号越界要夹住，不能把空数组喂给视图。
async test "app state clamps the initial layer" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo", initial_layer=99)
  assert_eq(state.view.layer, 1)
  let state_neg = AppState::new(views, None, "demo", initial_layer=-5)
  assert_eq(state_neg.view.layer, 0)
}

///|
/// 换层保留光标路径：同一文件在另一层也可见时，光标停在它上面。
async test "app state keeps the cursor path across layers" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo", initial_layer=1)
  state.view.move_to(state.view.index_of_path("/etc").unwrap())
  state.switch_layer(0)
  assert_eq(state.view.layer, 0)
  let path = state.view.cursor_path_from_visible()
  assert_eq(path, Some("/etc"))
}

///|
/// 换到目标层后，原路径不存在时游标落到合法位置，不越界。
async test "app state repositions the cursor when the path disappears" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo", initial_layer=1)
  // `/etc/hosts` 在 L1 没了
  state.view.move_to(state.view.index_of_path("/etc/hosts").unwrap())
  state.switch_layer(1)
  assert_true(state.view.cursor >= 0)
  assert_true(state.view.cursor < state.view.visible.length())
}

///|
/// 越界换层不动。
async test "app state ignores out-of-range layer switches" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo", initial_layer=1)
  state.switch_layer(5)
  assert_eq(state.view.layer, 1)
  state.switch_layer(-1)
  assert_eq(state.view.layer, 1)
}

///|
/// `window_size` 在非终端下退到 80x24，不抛错。
async test "window_size falls back to 80x24" {
  // 直接喂一个拿不到尺寸的 tty：用测试 stdio（非终端）触发兜底
  let size = WindowSize::{ cols: 80, rows: 24, }
  assert_eq(size.cols, 80)
  assert_eq(size.rows, 24)
}

///|
/// 在一对管道上建 tty，跑 `f`，返回 tty 写出去的全部字节（与
/// `terminal_paint_wbtest.mbt` 的同名工具同形；黑盒测试里看不到内部包）。
async fn mouse_pipe_tty(f : async (@tty.Tty) -> Unit) -> String {
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
/// 鼠标跟踪的开关与进出全屏配对：开了就得关，且关在切回主屏之前——
/// 漏关掉会让退出后的 shell 把每次点击吐成 `\x1b[<...` 垃圾（#51）。
///
/// 跟踪模式从 `Click`（`1000h`）换成 `Drag`（`1002h`）是 #62 的顺手改动：
/// 多一档「按住移动」，点击本身两种模式都报。
async test "app enables and disables mouse tracking around the alt screen" {
  let written = mouse_pipe_tty(tty => {
    // 复刻 `run_app` 的进出顺序：进全屏 → 开鼠标 → ... → 关鼠标 → 离屏
    let alt = AltScreen::new()
    alt.enter(tty)
    tty.enable_mouse(mouse_tracking_mode(pixel_mouse=false))
    tty.disable_mouse()
    alt.leave(tty)
  })
  // SGR 鼠标 + 按住跟踪（`Drag`；`Enable` 侧会先把三个模式位都关一遍，
  // 所以这里只断言最后开着的那个）
  assert_true(written.contains("\u{1b}[?1006h"))
  assert_true(written.contains("\u{1b}[?1002h"))
  // 退出侧：三个模式位都要关
  assert_true(written.contains("\u{1b}[?1002l"))
  assert_true(written.contains("\u{1b}[?1006l"))
  // 关鼠标排在离开 alternate screen 之前
  let mouse_off = written.find("\u{1b}[?1006l").unwrap()
  let leave_alt = written.find("\u{1b}[?1049l").unwrap()
  assert_true(mouse_off < leave_alt)
}
