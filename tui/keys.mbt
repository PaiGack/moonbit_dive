///|
/// 键盘动作：把 tty 的原始按键翻译成「看树」这一个语义层。
///
/// 抽这一层是为了能测：`Tty::read_event` 要真终端，但「哪颗键 → 哪个动作」
/// 是纯函数，单测直接喂 `KeyEvent` 就行，不用起伪终端。
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
  /// 下一张层级视图
  NextLayer
  Quit
  /// 没绑定的键
  None
} derive(Eq, Debug)

///|
/// 把一次按键翻成动作。
///
/// 绑定对齐 `less` / `dive` 的直觉：
/// `q`/`Esc`/`Ctrl+C` 退出，`↑↓`/`jk` 走行，`PgUp/PgDn`/`Space`/`b` 翻页，
/// `←`/`h` 收起、`→`/`l` 展开，`Tab` 切展开态，`[`/`]` 换层。
pub fn action_of_key(event : @input.KeyEvent) -> Action {
  // 只在按下 / 重复时响应：松开（Release）会重复触发，键盘收紧的模式下尤甚
  match event.kind {
    @input.KeyEventKind::Press | @input.KeyEventKind::Repeat => ()
    @input.KeyEventKind::Release => return Action::None
  }
  if event.modifiers.ctrl() {
    return match event.code {
      @input.KeyCode::Char('c') => Action::Quit
      _ => Action::None
    }
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
    @input.KeyCode::Tab => Action::Toggle
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
    _ => Action::None
  }
}

///|
/// 把动作施加到视图上；返回是否要退出主循环。
///
/// 换层动作用回调注入（`switch_layer`），因为「取上一层的树」要回到数据源，
/// 不是视图自己能做的事。视图只管「光标现在在哪」。
pub fn apply_action(
  action : Action,
  view : TreeView,
  switch_layer : (Int32) -> Unit,
) -> Bool {
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
    Action::PrevLayer => switch_layer_safe(view, switch_layer, view.layer - 1)
    Action::NextLayer => switch_layer_safe(view, switch_layer, view.layer + 1)
    Action::Quit => return true
    Action::None => ()
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
