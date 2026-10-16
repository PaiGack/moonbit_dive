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
  // `u` 是原版 dive 的 pgup 别名；`d` 那颗给了删除列表（#77），
  // `Space` 归位成折叠
  assert_eq(action_of_key(key(@input.KeyCode::Char('u'))), Action::PageUp)
  assert_eq(action_of_key(key(@input.KeyCode::PageUp)), Action::PageUp)
  assert_eq(action_of_key(key(@input.KeyCode::Char(' '))), Action::Toggle)
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
/// `Ctrl` 那一组（原版 dive 的 key config）：`ctrl+c` 退出、`ctrl+space` 全折叠、
/// `ctrl+a` / `ctrl+l` 切 diff 档位、`ctrl+u` 只看改写。
///
/// `ctrl+space` 在终端里是 NUL，tty 把它解成 `Char(' ') + ctrl`（真终端实测，
/// 不是「按 `Char('\u{0}')` 推导」）——这里就按那个形态钉住。
test "action_of_key maps the ctrl chords" {
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('c'), ctrl=true)),
    Action::Quit,
  )
  assert_eq(
    action_of_key(key(@input.KeyCode::Char(' '), ctrl=true)),
    Action::ToggleCollapseAll,
  )
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('a'), ctrl=true)),
    Action::CompareAggregate,
  )
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('l'), ctrl=true)),
    Action::CompareSingle,
  )
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('u'), ctrl=true)),
    Action::FilterModified,
  )
  // `ctrl+space` 与不带修饰的空格是两个不同事件：一个全折叠、一个折叠一行
  assert_eq(action_of_key(key(@input.KeyCode::Char(' '))), Action::Toggle)
  // 没绑的 ctrl 组合不响应（`ctrl+m` 与 `Enter` 同码位，绑了等于偷偷改 Enter；
  // `ctrl+b` 是 dive 的文件属性键，本仓常显不做）
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('m'), ctrl=true)),
    Action::None,
  )
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('b'), ctrl=true)),
    Action::None,
  )
}

///|
/// `Ctrl+Space` 全折叠 / 再按一次全展开，光标行被折掉时落到最近的祖先。
test "apply_action toggles collapse all" {
  let state = AppState::new(two_layers(), None, "demo", initial_layer=0)
  assert_false(apply_action(Action::ToggleCollapseAll, state))
  assert_true(state.view.collapsed.contains("/etc"))
  // 再按一次：全展（不是「再折一层」）
  assert_false(apply_action(Action::ToggleCollapseAll, state))
  assert_false(state.view.collapsed.contains("/etc"))
}

///|
/// `Ctrl+U` 只看改写过的行，再按一次撤销（`set_filter` 自带反转）。
test "apply_action toggles the modified-only filter" {
  let state = AppState::new(two_layers(), None, "demo", initial_layer=1)
  let total = state.view.visible.length()
  assert_false(apply_action(Action::FilterModified, state))
  assert_eq(state.view.only_group(), Some(RowGroup::ModifiedOnly))
  // L1 里只有 /etc/hosts 是改写的，其余行（/etc、/etc/extra）都被滤掉
  assert_true(state.view.visible.length() < total)
  for row in state.view.visible {
    assert_eq(row.status, RowStatus::Modified)
  }
  // 再按一次同一颗键 = 撤销（`set_filter` 自带反转，与 dive 的 `InvertFilter` 同效）
  assert_false(apply_action(Action::FilterModified, state))
  assert_eq(state.view.only_group(), None)
  assert_eq(state.view.visible.length(), total)
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

///|
/// `Ctrl+A` / `Ctrl+L` 的键位映射：与原版 dive 的 layer 面板同义。
test "action_of_key maps the compare mode keys" {
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('a'), ctrl=true)),
    Action::CompareAggregate,
  )
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('l'), ctrl=true)),
    Action::CompareSingle,
  )
  // 不带 Ctrl 的 `a` / `l` 不受影响：`l` 仍是展开
  assert_eq(action_of_key(key(@input.KeyCode::Char('a'))), Action::None)
  assert_eq(action_of_key(key(@input.KeyCode::Char('l'))), Action::Expand)
}

///|
/// `d` 开关删除列表；`d` 不带 Ctrl 才算，`Ctrl+D` 不绑。
test "action_of_key maps the removed list key" {
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('d'))),
    Action::ToggleRemoved,
  )
  assert_eq(
    action_of_key(key(@input.KeyCode::Char('d'), ctrl=true)),
    Action::None,
  )
}

///|
/// 造一个「聚合档与单层档不一样」的三层视图：`/etc/hosts` 在 L1 被改写、
/// L2 又改回 L0 的样子，`/etc/old` 在 L2 被删。
fn aggregate_layers() -> Array[@layer_tree.LayerView] {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
    @layer_tree.TarEntrySpec::File("etc/old", "x"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.2 longer"),
  ])
  let l2 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
    @layer_tree.TarEntrySpec::Whiteout("etc", "old"),
  ])
  @layer_tree.browse_layers([l0, l1, l2]) catch {
    err => abort(err.to_string())
  }
}

///|
/// 切档位：树形状不变（行数列数都一样），只有标注变。
///
/// 这是 issue #69 的第一条验收：换的是「比较区间」，不是数据源。
test "switching the compare mode keeps the tree and only re-colours" {
  let state = AppState::new(aggregate_layers(), None, "demo", initial_layer=2)
  let paths = state.view.all_rows.map(fn(row) { row.path })
  let statuses = state.view.all_rows.map(fn(row) { row.status })
  assert_false(apply_action(Action::CompareAggregate, state))
  assert_eq(state.view.compare_mode, CompareMode::Aggregate)
  // 树一模一样
  assert_eq(state.view.all_rows.map(fn(row) { row.path }), paths)
  // 标注变了：`/etc/hosts` 在单层档里因为 L2 改写了它是 Modified，
  // 聚合档里同样是 Modified（区间内碰过），但它的祖先 `/etc` 也被合并进来
  assert_true(
    state.view.all_rows.any(fn(row) { row.path == "/etc" }) &&
    status_of_row(state, "/etc") == RowStatus::Modified,
  )
  // 切回来恢复原状
  assert_false(apply_action(Action::CompareSingle, state))
  assert_eq(state.view.compare_mode, CompareMode::Single)
  assert_eq(state.view.all_rows.map(fn(row) { row.status }), statuses)
}

///|
/// 取某条路径在视图里的状态；找不到时按 `Unchanged`。
fn status_of_row(state : AppState, path : String) -> RowStatus {
  for row in state.view.all_rows {
    if row.path == path {
      return row.status
    }
  }
  RowStatus::Unchanged
}

///|
/// 聚合档下 `removed` 有出口：`d` 打开列表，列表内容就是聚合 diff 的 `removed`。
test "the removed list is filled from the active compare mode" {
  let state = AppState::new(aggregate_layers(), None, "demo", initial_layer=2)
  // 单层档：只有 L2 自己删的那条
  assert_eq(state.removed_paths(), ["/etc/old"])
  ignore(apply_action(Action::CompareAggregate, state))
  // 聚合档：整段区间删掉的路径——`/etc/old` 在 L2 被删，`/etc/hosts`
  // 在两档里都不算删除（两头都在），所以列表仍是这一条
  assert_eq(state.removed_paths(), ["/etc/old"])
  // `d` 开关浮层；开着时 ↑↓ 滚列表，不动树的光标
  let cursor = state.view.cursor
  assert_false(apply_action(Action::ToggleRemoved, state))
  assert_true(state.removed_visible)
  assert_false(apply_action(Action::MoveDown, state))
  assert_eq(state.view.cursor, cursor)
  assert_false(apply_action(Action::ToggleRemoved, state))
  assert_false(state.removed_visible)
}

///|
/// 换层保留档位：在聚合档里换层，不该悄悄回到单层档。
test "layer switching keeps the compare mode" {
  let state = AppState::new(aggregate_layers(), None, "demo", initial_layer=0)
  ignore(apply_action(Action::CompareAggregate, state))
  assert_false(apply_action(Action::NextLayer, state))
  assert_eq(state.view.compare_mode, CompareMode::Aggregate)
  // 排序口径同样跟着走
  ignore(apply_action(Action::ToggleSort, state))
  assert_true(state.view.sort_by_size)
  assert_eq(state.view.compare_mode, CompareMode::Aggregate)
}
