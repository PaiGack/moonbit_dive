///|
/// 造一个两层的逐层视图（与 `app_wbtest.mbt` 的同名工具同形，
/// 但黑盒测试里看不到内部包，所以各自留一份）。
fn two_layers() -> Array[@layer_tree.LayerView] {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "a"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "bb"),
    @layer_tree.TarEntrySpec::File("etc/extra", "c"),
  ])
  @layer_tree.browse_layers([l0, l1]) catch {
    err => abort(err.to_string())
  }
}

///|
/// 造一个按键事件（默认 Press）。
fn key(
  code : @input.KeyCode,
  ctrl~ : Bool = false,
  shift~ : Bool = false,
) -> @input.KeyEvent {
  @input.KeyEvent::new(code, modifiers=@input.KeyModifiers::new(ctrl~, shift~))
}

///|
/// 核心键位映射。
test "action_of_key maps navigation keys" {
  assert_eq(action_of_key(key(@input.KeyCode::Up)), Action::MoveUp)
  assert_eq(action_of_key(key(@input.KeyCode::Down)), Action::MoveDown)
  assert_eq(action_of_key(key(@input.KeyCode::Char('j'))), Action::MoveDown)
  assert_eq(action_of_key(key(@input.KeyCode::Char('k'))), Action::MoveUp)
  assert_eq(action_of_key(key(@input.KeyCode::PageDown)), Action::PageDown)
  assert_eq(action_of_key(key(@input.KeyCode::Char(' '))), Action::PageDown)
  assert_eq(action_of_key(key(@input.KeyCode::PageUp)), Action::PageUp)
  assert_eq(action_of_key(key(@input.KeyCode::Char('b'))), Action::PageUp)
  assert_eq(action_of_key(key(@input.KeyCode::Home)), Action::Home)
  assert_eq(action_of_key(key(@input.KeyCode::Char('g'))), Action::Home)
  assert_eq(action_of_key(key(@input.KeyCode::End)), Action::End)
  assert_eq(action_of_key(key(@input.KeyCode::Char('G'))), Action::End)
}

///|
/// 展开/收起/换层/退出。
test "action_of_key maps fold and layer keys" {
  assert_eq(action_of_key(key(@input.KeyCode::Left)), Action::Collapse)
  assert_eq(action_of_key(key(@input.KeyCode::Char('h'))), Action::Collapse)
  assert_eq(action_of_key(key(@input.KeyCode::Right)), Action::Expand)
  assert_eq(action_of_key(key(@input.KeyCode::Char('l'))), Action::Expand)
  assert_eq(action_of_key(key(@input.KeyCode::Enter)), Action::Toggle)
  // Tab 在全屏形态里让给「切焦点」，展开/收起仍有 Enter 与 ←→ 三条路
  assert_eq(action_of_key(key(@input.KeyCode::Tab)), Action::NextFocus)
  assert_eq(action_of_key(key(@input.KeyCode::Char('['))), Action::PrevLayer)
  assert_eq(action_of_key(key(@input.KeyCode::Char(']'))), Action::NextLayer)
  assert_eq(action_of_key(key(@input.KeyCode::Char('q'))), Action::Quit)
  assert_eq(action_of_key(key(@input.KeyCode::Escape)), Action::Quit)
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('c'), ctrl=true)),
    Action::Quit,
  )
}

///|
/// 没绑定的键给 None，不会误触。
test "action_of_key ignores unbound keys" {
  assert_eq(action_of_key(key(@input.KeyCode::Char('z'))), Action::None)
  assert_eq(action_of_key(key(@input.KeyCode::F5)), Action::None)
  // Ctrl + 非 c 不响应，避免和终端自己的快捷键打架
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('j'), ctrl=true)),
    Action::None,
  )
}

///|
/// 松开键不响应：否则同一颗键会被算两次。
test "action_of_key ignores key release" {
  let release = @input.KeyEvent::new(
    @input.KeyCode::Down,
    kind=@input.KeyEventKind::Release,
  )
  assert_eq(action_of_key(release), Action::None)
}

///|
/// 重复键（长按）按按下处理。
test "action_of_key accepts key repeat" {
  let repeat = @input.KeyEvent::new(
    @input.KeyCode::Down,
    kind=@input.KeyEventKind::Repeat,
  )
  assert_eq(action_of_key(repeat), Action::MoveDown)
}

///|
/// 焦点键与帮助键与树无关：Tab 切焦点、? 开关帮助面板。
test "action_of_key maps focus and help keys" {
  assert_eq(action_of_key(key(@input.KeyCode::Tab)), Action::NextFocus)
  assert_eq(
    action_of_key(key(@input.KeyCode::Tab, shift=true)),
    Action::PrevFocus,
  )
  assert_eq(action_of_key(key(@input.KeyCode::Char('?'))), Action::ToggleHelp)
}

///|
/// 焦点面板上动作走详情滚动：移动类动作直接反映在滚动偏移上。
test "apply_action scrolls the detail pane when it is focused" {
  let state = AppState::new(two_layers(), None, "demo")
  state.focus = Focus::Detail
  // 详情内容 10 行，窗口 3 行
  state.detail_scroll.set_content(10)
  state.detail_scroll.window = 3
  assert_false(apply_action(Action::MoveDown, state))
  assert_eq(state.detail_scroll.offset, 1)
  assert_false(apply_action(Action::End, state))
  assert_eq(state.detail_scroll.offset, 7)
  // 光标不受影响：焦点在详情时不该偷偷动树
  assert_eq(state.view.cursor, 0)
  // 树的展开/折叠在详情面板上没有落点，静默忽略
  assert_false(apply_action(Action::Expand, state))
}

///|
/// 切焦点与帮助开关都不退出；帮助展开时走行动作被忽略（浮层内容固定）。
test "apply_action handles focus switching and the help overlay" {
  let state = AppState::new([], None, "demo")
  assert_false(apply_action(Action::NextFocus, state))
  assert_eq(state.focus, Focus::Detail)
  assert_false(apply_action(Action::NextFocus, state))
  assert_eq(state.focus, Focus::Tree)
  assert_false(apply_action(Action::PrevFocus, state))
  assert_eq(state.focus, Focus::Detail)
  assert_false(apply_action(Action::ToggleHelp, state))
  assert_true(state.help_visible)
  // 浮层开着：走行不生效（避免看不见的光标在动）
  assert_false(apply_action(Action::MoveDown, state))
  // 但关帮助与退出仍然响应
  assert_false(apply_action(Action::ToggleHelp, state))
  assert_false(state.help_visible)
  assert_true(apply_action(Action::Quit, state))
}

///|
/// 动作施加到视图上：移动类动作直接反映在光标上，退出返回 true。
test "apply_action drives the view and signals quit" {
  let state = AppState::new(two_layers(), None, "demo", initial_layer=0)
  state.view.move_to_home()
  state.view.page_height = 10
  assert_false(apply_action(Action::MoveDown, state))
  assert_eq(state.view.cursor, 1)
  assert_false(apply_action(Action::MoveUp, state))
  assert_eq(state.view.cursor, 0)
  assert_true(apply_action(Action::Quit, state))
}

///|
/// 换层动作只在合法范围内生效，且不退出。
test "apply_action clamps layer switching" {
  let views = two_layers()
  let state = AppState::new(views, None, "demo", initial_layer=1)
  assert_false(apply_action(Action::PrevLayer, state))
  assert_eq(state.view.layer, 0)
  assert_false(apply_action(Action::NextLayer, state))
  assert_eq(state.view.layer, 1)
  // 已经是最后一层：越界不动
  assert_false(apply_action(Action::NextLayer, state))
  assert_eq(state.view.layer, 1)
}

///|
/// `s` 切排序口径：切一次按大小，再切一次回名字。
test "apply_action toggles the sort order" {
  let state = AppState::new(two_layers(), None, "demo", initial_layer=0)
  assert_false(state.view.sort_by_size)
  assert_false(apply_action(Action::ToggleSort, state))
  assert_true(state.view.sort_by_size)
  assert_false(apply_action(Action::ToggleSort, state))
  assert_false(state.view.sort_by_size)
}

///|
/// `s` 的键位映射。
test "action_of_key maps the sort key" {
  assert_eq(action_of_key(key(@input.KeyCode::Char('s'))), Action::ToggleSort)
}

///|
/// 换层保留排序口径：切到大小序再换层，不该悄悄回到名字序。
test "layer switching keeps the sort order" {
  let state = AppState::new(two_layers(), None, "demo", initial_layer=0)
  ignore(apply_action(Action::ToggleSort, state))
  assert_false(apply_action(Action::NextLayer, state))
  assert_true(state.view.sort_by_size)
}
