///|
/// L3 键盘动作：把 tty 的原始按键翻译成「看树」这一个语义层。
///
/// 抽这一层是为了能测：`Tty::read_event` 要真终端，但「哪颗键 → 哪个动作」
/// 是纯函数，单测直接喂 `KeyEvent` 就行，不用起伪终端。
///
/// 全屏形态下动作多了一类**焦点相关**的（切面板、开关帮助）：同一个 `↑`
/// 在树上是「下一行」、在详情面板上是「往下滚」，所以动作表本身仍然与焦点无关，
/// 「动作 → 状态」这一步（`apply_action`）才看焦点。
pub(all) enum Action {
  MoveUp
  MoveDown
  PageUp
  PageDown
  Home
  End
  /// 展开 / 收起 / 进入子目录
  Expand
  /// 收起 / 回到父目录
  Collapse
  Toggle
  /// 上一张层级视图（看上一层）
  PrevLayer
  /// 下一张层级视图（看下一层）
  NextLayer
  /// 切到下一个面板
  NextFocus
  /// 切到上一个面板（Shift+Tab）
  PrevFocus
  /// 开关帮助浮层
  ToggleHelp
  /// 按大小排序（再按一次回名字序）
  ToggleSort
  /// diff 档位切到「聚合」（当前层相对第 0 层之前的整段累积）
  CompareAggregate
  /// diff 档位切回「当前层」（相对上一层）
  CompareSingle
  /// 开关删除路径列表浮层
  ToggleRemoved
  Quit
  /// 没绑定的键
  None
} derive(Eq, Debug)

///|
/// 把一次按键翻成动作。
///
/// 绑定对齐 `less` / `dive` 的直觉：
/// `q`/`Esc`/`Ctrl+C` 退出，`↑↓`/`jk` 走行，`PgUp/PgDn`/`Space`/`b` 翻页，
/// `←`/`h` 收起、`→`/`l` 展开，`Tab` 切展开态，
/// `[`/`]` 换层，全屏形态另加 `Tab`/`Shift+Tab` 切焦点、`?` 开关帮助、
/// `s` 切换「按名字 / 按大小」排序（鼠标那侧是右键，见 `./mouse.mbt`），
/// `d` 开关删除路径列表，`Ctrl+A` / `Ctrl+L` 切「聚合 / 当前层」的 diff 档位。
///
/// `Tab` 在路径 A 里是「切展开态」，这里改成「切焦点」——全屏下多面板
/// 必须有切焦点的键，而切展开态有 `Enter` 与 `←→` 两条路，不差这一个。
pub fn action_of_key(event : @input.KeyEvent) -> Action {
  // 只在按下 / 重复时响应：松开（Release）会重复触发，键盘收紧的模式下尤甚
  match event.kind {
    @input.KeyEventKind::Press | @input.KeyEventKind::Repeat => ()
    @input.KeyEventKind::Release => return Action::None
  }
  if event.modifiers.ctrl() {
    // `Ctrl+A` / `Ctrl+L` 与原版 dive 的 layer 面板同义：切「聚合 / 当前层」档位。
    // 它们在本仓未被占用；filetree 面板那组 `Ctrl+A/R/M/U`（按状态过滤）是 #64 的盘子，
    // 两边别各绑一个。
    return match event.code {
      @input.KeyCode::Char('c') => Action::Quit
      @input.KeyCode::Char('a') => Action::CompareAggregate
      @input.KeyCode::Char('l') => Action::CompareSingle
      _ => Action::None
    }
  }
  // Tab 切焦点；Shift+Tab 反向。终端把两种都送到 `Tab` 上，靠修饰键区分
  if event.code == @input.KeyCode::Tab {
    if event.modifiers.shift() {
      return Action::PrevFocus
    }
    return Action::NextFocus
  }
  match event.code {
    @input.KeyCode::Up => Action::MoveUp
    @input.KeyCode::Down => Action::MoveDown
    @input.KeyCode::PageUp => Action::PageUp
    @input.KeyCode::PageDown => Action::PageDown
    @input.KeyCode::Home => Action::Home
    @input.KeyCode::End => Action::End
    @input.KeyCode::Left => Action::Collapse
    @input.KeyCode::Right => Action::Expand
    @input.KeyCode::Enter => Action::Toggle
    @input.KeyCode::Escape => Action::Quit
    @input.KeyCode::Char('q') => Action::Quit
    @input.KeyCode::Char('j') => Action::MoveDown
    @input.KeyCode::Char('k') => Action::MoveUp
    @input.KeyCode::Char('h') => Action::Collapse
    @input.KeyCode::Char('l') => Action::Expand
    @input.KeyCode::Char(' ') => Action::PageDown
    @input.KeyCode::Char('b') => Action::PageUp
    @input.KeyCode::Char('g') => Action::Home
    @input.KeyCode::Char('G') => Action::End
    @input.KeyCode::Char('[') => Action::PrevLayer
    @input.KeyCode::Char(']') => Action::NextLayer
    @input.KeyCode::Char('?') => Action::ToggleHelp
    @input.KeyCode::Char('s') => Action::ToggleSort
    @input.KeyCode::Char('d') => Action::ToggleRemoved
    _ => Action::None
  }
}

///|
/// 把动作施加到状态上；返回是否要退出主循环。
///
/// 分派规则：
///
/// - **焦点相关**（切面板 / 帮助）：与焦点无关地生效
/// - **换层**：始终作用于树（详情面板看的就是树的光标），因此不做焦点区分
/// - **走行 / 翻页 / 展开收起**：看焦点——焦点在详情面板时 `↑↓` 滚详情
/// - **帮助浮层展开时**：`↑↓` 不给树，留给浮层滚动（本轮浮层内容固定，
///   按「先关掉再说」处理：任何走行动作直接忽略，避免看不见的光标在动）
///
/// 这一层是纯状态机，除了 `switch_layer` 回调（要回到数据源换树）没有副作用。
pub fn apply_action(action : Action, state : AppState) -> Bool {
  // 帮助浮层开着时，除退出 / 关帮助 / 切焦点外一律忽略
  if state.help_visible {
    match action {
      Action::Quit => return true
      Action::ToggleHelp | Action::NextFocus | Action::PrevFocus => ()
      Action::None => ()
      _ => return false
    }
  }
  // 删除列表浮层：只有滚动 / 关闭有效，别的键不穿透到树上去
  // （与帮助浮层一个口径：看不见的光标不该动）
  if state.removed_visible {
    match action {
      Action::Quit => return true
      Action::ToggleRemoved => {
        state.toggle_removed()
        return false
      }
      Action::MoveUp => state.removed_scroll.scroll_by(-1)
      Action::MoveDown => state.removed_scroll.scroll_by(1)
      Action::PageUp => state.removed_scroll.scroll_page(-1)
      Action::PageDown => state.removed_scroll.scroll_page(1)
      Action::Home => state.removed_scroll.to_top()
      Action::End => state.removed_scroll.to_bottom()
      Action::None => ()
      _ => ()
    }
    return false
  }
  match action {
    Action::Quit => return true
    Action::ToggleHelp => {
      state.help_visible = !state.help_visible
      return false
    }
    Action::ToggleSort => {
      state.toggle_sort()
      return false
    }
    Action::CompareAggregate => {
      state.switch_compare_mode(CompareMode::Aggregate)
      return false
    }
    Action::CompareSingle => {
      state.switch_compare_mode(CompareMode::Single)
      return false
    }
    Action::ToggleRemoved => {
      state.toggle_removed()
      return false
    }
    Action::NextFocus => {
      state.focus = state.focus.next()
      return false
    }
    Action::PrevFocus => {
      state.focus = state.focus.prev()
      return false
    }
    Action::PrevLayer =>
      switch_layer_safe(
        state.view,
        layer => state.switch_layer(layer),
        state.view.layer - 1,
      )
    Action::NextLayer =>
      switch_layer_safe(
        state.view,
        layer => state.switch_layer(layer),
        state.view.layer + 1,
      )
    _ => ()
  }
  if state.focus == Focus::Detail {
    // 详情面板只有「滚」这一件事；展开/折叠/换层这类动作在这里没有落点，
    // 静默忽略而不是偷偷转给树——按键反馈不一致比没反应更让人困惑
    match action {
      Action::MoveUp => state.detail_scroll.scroll_by(-1)
      Action::MoveDown => state.detail_scroll.scroll_by(1)
      Action::PageUp => state.detail_scroll.scroll_page(-1)
      Action::PageDown => state.detail_scroll.scroll_page(1)
      Action::Home => state.detail_scroll.to_top()
      Action::End => state.detail_scroll.to_bottom()
      Action::None => ()
      _ => ()
    }
    return false
  }
  let view = state.view
  let page = max(view.page_size(), 1)
  match action {
    Action::MoveUp => view.move_up()
    Action::MoveDown => view.move_down()
    Action::PageUp => view.page_up(page)
    Action::PageDown => view.page_down(page)
    Action::Home => view.move_to_home()
    Action::End => view.move_to_end()
    Action::Expand => view.expand()
    Action::Collapse => view.collapse()
    Action::Toggle => view.toggle()
    Action::None => ()
    // 上面已处理：这里再列一遍是为了让 `match` 穷尽，编译器会盯住新增动作
    Action::PrevLayer
    | Action::NextLayer
    | Action::NextFocus
    | Action::PrevFocus
    | Action::ToggleHelp
    | Action::ToggleSort
    | Action::CompareAggregate
    | Action::CompareSingle
    | Action::ToggleRemoved
    | Action::Quit => ()
  }
  false
}

///|
/// 换层：越界不动，合法就回调数据源换树。回调负责重建 `all_rows` 与 `visible`。
fn switch_layer_safe(
  view : TreeView,
  switch_layer : (Int32) -> Unit,
  target : Int32,
) -> Unit {
  if target < 0 || target >= view.total_layers {
    return
  }
  switch_layer(target)
}

///|
pub extend Action with Eq::{equal, not_equal}

///|
pub extend Action with @debug.Debug::{to_repr}
