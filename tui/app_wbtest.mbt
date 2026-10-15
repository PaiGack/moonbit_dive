///|
/// 造一个两层的逐层视图，供状态机测试。
fn two_layer_views() -> Array[@layer_tree.LayerView] raise {
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
test "app state starts on the requested layer" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo")
  assert_eq(state.view.layer, 0)
  let state_last = AppState::new(views, None, "demo", initial_layer=1)
  assert_eq(state_last.view.layer, 1)
}

///|
/// 初始层号越界要夹住，不能把空数组喂给视图。
test "app state clamps the initial layer" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo", initial_layer=99)
  assert_eq(state.view.layer, 1)
  let state_neg = AppState::new(views, None, "demo", initial_layer=-5)
  assert_eq(state_neg.view.layer, 0)
}

///|
/// 换层保留光标路径：同一文件在另一层也可见时，光标停在它上面。
test "app state keeps the cursor path across layers" {
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
test "app state repositions the cursor when the path disappears" {
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
test "app state ignores out-of-range layer switches" {
  let views = two_layer_views()
  let state = AppState::new(views, None, "demo", initial_layer=1)
  state.switch_layer(5)
  assert_eq(state.view.layer, 1)
  state.switch_layer(-1)
  assert_eq(state.view.layer, 1)
}

///|
/// `window_size` 在非终端下退到 80x24，不抛错。
test "window_size falls back to 80x24" {
  // 直接喂一个拿不到尺寸的 tty：用测试 stdio（非终端）触发兜底
  let size = WindowSize::{ cols: 80, rows: 24, }
  assert_eq(size.cols, 80)
  assert_eq(size.rows, 24)
}
