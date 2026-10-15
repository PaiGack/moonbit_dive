///|
/// 造一个两层的逐层视图（与 `app_wbtest.mbt` 的同名工具同形）。
fn mouse_views() -> Array[@layer_tree.LayerView] raise {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "a"),
    @layer_tree.TarEntrySpec::File("etc/passwd", "bb"),
  ])
  @layer_tree.build_tar([@layer_tree.TarEntrySpec::File("etc/hosts", "ccc")])
  |> ignore
  @layer_tree.browse_layers([l0])
}

///|
/// 造一个已经画过一帧的状态：`last_layout` 有值，鼠标坐标才有落点。
fn mouse_state() -> AppState raise {
  let state = AppState::new(mouse_views(), None, "demo")
  let layout = Layout::compute(80, 24)
  state.view.page_height = max(layout.body_height() - 1, 1)
  state.last_layout = Some(layout)
  state
}

///|
/// 建鼠标事件（坐标是终端格的 1 起口径）。
fn mouse_at(
  kind : @input.MouseEventKind,
  row : Int32,
  col : Int32,
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
/// 命中测试：两块面板各自认出自己，行号是**内容区内的相对行**。
///
/// 80x24 下树的内容区从第 2 行（0 起）起笔，即终端的第 3 行；
/// 详情面板从第 42 列（0 起）起笔，即终端的第 43 列。
test "hit test resolves panes and relative rows" {
  let layout = Layout::compute(80, 24)
  // 树内容区的第一行
  assert_eq(hit_test(layout, 3, 2), Some((PaneId::Tree, 0)))
  // 树内容区的第三行
  assert_eq(hit_test(layout, 5, 2), Some((PaneId::Tree, 2)))
  // 详情面板第一行；列落在右栏中间
  assert_eq(hit_test(layout, 3, 60), Some((PaneId::Detail, 0)))
  // 标题行（第 1 行）不属于任何面板
  assert_eq(hit_test(layout, 1, 2), None)
  // 状态行（最后一行）不接鼠标
  assert_eq(hit_test(layout, 24, 2), None)
  // 1 起的坐标：第 0 行 / 第 0 列是非法输入
  assert_eq(hit_test(layout, 0, 2), None)
  assert_eq(hit_test(layout, 3, 0), None)
}

///|
/// 窄屏退化单栏时，右栏的坐标落不到详情面板上（面板不存在，不该被凭空命中）。
test "hit test has no detail pane on a narrow terminal" {
  let layout = Layout::compute(30, 20)
  assert_eq(layout.pane(PaneId::Detail), None)
  assert_eq(hit_test(layout, 3, 40), None)
  // 左栏照常
  assert_eq(hit_test(layout, 3, 2), Some((PaneId::Tree, 0)))
}

///|
/// 点在树上：选中那一行，并把键盘焦点交给树。
test "click selects a tree row and focuses the tree" {
  let state = mouse_state()
  state.focus = Focus::Detail
  let quit = handle_mouse(
    mouse_at(@input.MouseEventKind::Press(@input.MouseButton::Left), 5, 3),
    state,
  )
  assert_false(quit)
  assert_eq(state.focus, Focus::Tree)
  // 内容区第 3 行（0 起）= 屏幕第 5 行 → 可见行下标 2
  assert_eq(state.view.cursor, 2)
}

///|
/// 点在详情面板：焦点切过去，树的光标不动。
test "click on the detail pane only moves the focus" {
  let state = mouse_state()
  state.view.move_to(1)
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Press(@input.MouseButton::Left), 5, 60),
      state,
    ),
  )
  assert_eq(state.focus, Focus::Detail)
  assert_eq(state.view.cursor, 1)
}

///|
/// 点空白（内容区里的空白格）什么都不做：不选行，也不抢焦点。
test "click on empty space in the pane changes nothing" {
  let state = mouse_state()
  state.focus = Focus::Detail
  state.view.move_to(1)
  // 树的可见行只有 3 行，屏幕第 20 行在内容区内但是空白
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Press(@input.MouseButton::Left), 20, 3),
      state,
    ),
  )
  assert_eq(state.focus, Focus::Detail)
  assert_eq(state.view.cursor, 1)
}

///|
/// 滚轮：树上滚光标，详情上滚视口——鼠标在哪块就滚哪块，不需要先点一下。
test "wheel scrolls the pane under the pointer" {
  let state = mouse_state()
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Scroll(@input.MouseScroll::Down), 3, 3),
      state,
    ),
  )
  // 滚轮一步 3 行，只有 3 行可见行，光标夹在末行
  assert_eq(state.view.cursor, 2)
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Scroll(@input.MouseScroll::Up), 5, 3),
      state,
    ),
  )
  assert_eq(state.view.cursor, 0)
  // 详情面板：滚的是视口，不是树
  state.detail_scroll.set_content(50)
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Scroll(@input.MouseScroll::Down), 3, 60),
      state,
    ),
  )
  assert_eq(state.detail_scroll.offset, 3)
  assert_eq(state.view.cursor, 0)
}

///|
/// 右键点目录行：切展开状态；点文件行不动。
test "right click toggles the fold of the row under the pointer" {
  let state = mouse_state()
  let dir_row = state.view.index_of_path("/etc").unwrap()
  // `/etc` 是第 0 行可见行 → 内容区第 0 行 → 屏幕第 3 行
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Press(@input.MouseButton::Right), 3, 3),
      state,
    ),
  )
  assert_eq(dir_row, 0)
  assert_true(state.view.collapsed.contains("/etc"))
  // 再点一次展开回来
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Press(@input.MouseButton::Right), 3, 3),
      state,
    ),
  )
  assert_false(state.view.collapsed.contains("/etc"))
}

///|
/// 拖拽 / 移动不产生任何状态变化（本轮不做拖拽与框选）。
test "drag and move never change the state" {
  let state = mouse_state()
  state.view.move_to(2)
  let snapshot = state.view.cursor
  ignore(handle_mouse(mouse_at(@input.MouseEventKind::Move, 3, 3), state))
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Drag(@input.MouseButton::Left), 6, 3),
      state,
    ),
  )
  assert_eq(state.view.cursor, snapshot)
  assert_eq(state.focus, Focus::Tree)
}

///|
/// 还没画过帧时（`last_layout` 为空）鼠标事件被安静丢掉，不崩。
test "mouse events before the first frame are ignored" {
  let state = AppState::new(mouse_views(), None, "demo")
  assert_eq(state.last_layout, None)
  let quit = handle_mouse(
    mouse_at(@input.MouseEventKind::Press(@input.MouseButton::Left), 3, 3),
    state,
  )
  assert_false(quit)
  assert_eq(state.view.cursor, 0)
}

///|
/// 帮助浮层开着时，点击不穿透到浮层底下的面板。
test "clicks do not fall through the help overlay" {
  let state = mouse_state()
  state.help_visible = true
  state.view.move_to(0)
  ignore(
    handle_mouse(
      mouse_at(@input.MouseEventKind::Press(@input.MouseButton::Left), 20, 3),
      state,
    ),
  )
  assert_eq(state.view.cursor, 0)
}
