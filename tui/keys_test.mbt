///|
/// 造一个按键事件（默认 Press）。
fn key(code : @input.KeyCode, ctrl~ : Bool = false) -> @input.KeyEvent {
  @input.KeyEvent::new(code, modifiers=@input.KeyModifiers::new(ctrl~))
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
  assert_eq(action_of_key(key(@input.KeyCode::Tab)), Action::Toggle)
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
/// 动作施加到视图上：移动类动作直接反映在光标上，退出返回 true。
test "apply_action drives the view and signals quit" {
  let tree = @layer_tree.FileTree::new()
  let tar = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "x"),
    @layer_tree.TarEntrySpec::File("etc/passwd", "y"),
  ])
  @layer_tree.apply_layer(tree, tar, 0) catch {
    err => fail(err.to_string())
  }
  let view = TreeView::from_tree(tree, 0, 1)
  let mut switched = -1
  let switch = fn(layer) { switched = layer }
  assert_false(apply_action(Action::MoveDown, view, switch))
  assert_eq(view.cursor, 1)
  assert_false(apply_action(Action::MoveUp, view, switch))
  assert_eq(view.cursor, 0)
  assert_true(apply_action(Action::Quit, view, switch))
  assert_eq(switched, -1)
}

///|
/// 换层动作只在合法范围内回调，且不退出。
test "apply_action clamps layer switching" {
  let tree = @layer_tree.FileTree::new()
  let view = TreeView::from_tree(tree, 1, 3)
  let mut switched = -1
  let switch = fn(layer) { switched = layer }
  // 上一层合法
  assert_false(apply_action(Action::PrevLayer, view, switch))
  assert_eq(switched, 0)
  // 下一层合法
  switched = -1
  assert_false(apply_action(Action::NextLayer, view, switch))
  assert_eq(switched, 2)
  // 越界不回调
  switched = -1
  let head = TreeView::from_tree(tree, 0, 3)
  assert_false(apply_action(Action::PrevLayer, head, switch))
  assert_eq(switched, -1)
}
