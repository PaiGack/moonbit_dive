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
  /// 全折叠 / 全展开（`Ctrl+Space`）
  ToggleCollapseAll
  /// 比较所有层（`Ctrl+A`）
  CompareAll
  /// 只看「被改写」的行（`Ctrl+L`；`Ctrl+U` 是撤销过滤）
  FilterModified
  /// 撤销 diff 过滤（`Ctrl+U`）
  FilterClear
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
  Quit
  /// 没绑定的键
  None
} derive(Eq, Debug)

///|
/// 把一次按键翻成动作。**这一张表逐条对齐原版 dive 的 `DefaultBindings()`**
/// （`cmd/dive/cli/internal/ui/v1/key/config.go`），不留差异：
///
/// | 作用域 | 动作 | 默认键 |
/// |---|---|---|
/// | Global | Quit | `ctrl+c` |
/// | Global | ToggleView | `tab` |
/// | Navigation | Up/Down/Left/Right | `up,k` / `down,j` / `left,h` / `right,l` |
/// | Navigation | PageUp/PageDown | `pgup,u` / `pgdn,d` |
/// | Layer | CompareAll / CompareLayer | `ctrl+a` / `ctrl+l` |
/// | Filetree | ToggleCollapseDir / AllDir | `space` / `ctrl+space` |
/// | Filetree | 过滤 unmodified | `ctrl+u` |
/// | Filetree | ToggleShowAttributes | `ctrl+b` |
/// | Filetree | 排序（ToggleSortOrder） | `ctrl+o` |
///
/// 本仓原来的绑定（`q`/`Esc` 退出、`[`/`]` 换层、`s` 排序、`g`/`G` 到顶到底、
/// `?` 帮助）原版没有对应键，按「只增不改」保留，所以这张表是**原版键位的超集**。
/// 原版里本仓**明确不做**的两条（`Ctrl+F` 过滤、`Ctrl+E` 抽文件）
/// 不是「忘了对齐」，原因写在 `docs/p6-tui.md` 的差异说明里。
///
/// 三条容易踩的地方：
///
/// - **`Ctrl` 要先判，且只认列出来的那几颗**：`Ctrl+M` 与 `Enter` 同码位（`0x0d`）、
///   `Ctrl+J` 与换行同码位，绑上它们等于偷偷改了 `Enter` / `j`
/// - **`Ctrl+Space` 是 `Char(' ')` + ctrl**（NUL，实测确认），
///   与不带修饰的 `Space` 是两个不同事件，因此「空格折叠、Ctrl+空格全折叠」可以共存
/// - **`Enter` 与 `Tab` 在往上判之前处理**：kitty 键盘协议下 `Shift+Tab` 会落在
///   `code == Tab` + shift 上，不能让它掉进 `Char` 分支
pub fn action_of_key(event : @input.KeyEvent) -> Action {
  // 只在按下 / 重复时响应：松开（Release）会重复触发，键盘收紧的模式下尤甚
  match event.kind {
    @input.KeyEventKind::Press | @input.KeyEventKind::Repeat => ()
    @input.KeyEventKind::Release => return Action::None
  }
  // Tab 换视图（原版 ToggleView），Shift+Tab 反向。终端把两种都送到 `Tab` 上
  if event.code == @input.KeyCode::Tab {
    if event.modifiers.shift() {
      return Action::PrevFocus
    }
    return Action::NextFocus
  }
  if event.modifiers.ctrl() {
    return match event.code {
      @input.KeyCode::Char('c') => Action::Quit
      // `ctrl+space`：NUL 在 tty 里解成 `Char(' ') + ctrl`（实测），不是 `Char('\u{0}')`
      @input.KeyCode::Char(' ') => Action::ToggleCollapseAll
      @input.KeyCode::Char('a') => Action::CompareAll
      @input.KeyCode::Char('l') => Action::FilterModified
      @input.KeyCode::Char('u') => Action::FilterClear
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
    @input.KeyCode::Escape => Action::Quit
    @input.KeyCode::Char('q') => Action::Quit
    @input.KeyCode::Char('j') => Action::MoveDown
    @input.KeyCode::Char('k') => Action::MoveUp
    @input.KeyCode::Char('h') => Action::Collapse
    @input.KeyCode::Char('l') => Action::Expand
    // 原版：`space` 折叠目录，`pgdn` 翻页。本仓原来把 `space` 绑成 `pgdn`，
    // 那是最初「翻页键不够用」时的临时口径（`b` 也是当时补的），
    // 现在按原版归位：翻页有 `pgup/pgdn` 两颗键，折叠有 `space`
    @input.KeyCode::Char(' ') => Action::Toggle
    @input.KeyCode::Char('u') => Action::PageUp
    @input.KeyCode::Char('d') => Action::PageDown
    @input.KeyCode::Char('g') => Action::Home
    @input.KeyCode::Char('G') => Action::End
    @input.KeyCode::Char('[') => Action::PrevLayer
    @input.KeyCode::Char(']') => Action::NextLayer
    @input.KeyCode::Char('?') => Action::ToggleHelp
    @input.KeyCode::Char('s') => Action::ToggleSort
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
    // `Ctrl+A`（原版 CompareAll）：本仓没有「层信息面板」，这个动作的承载面
    // 落到**详情面板**——它本来就把「这一层动了什么」摊在屏幕上（#64 的口径）。
    // 面板不存在（窄屏退化）时不硬造一个，静默忽略。
    Action::CompareAll => {
      if state.has_detail_pane() {
        state.focus = Focus::Detail
        state.detail_scroll.to_top()
      }
      return false
    }
    // `Ctrl+L` / `Ctrl+U`：只看「被改写」的行 / 撤销过滤。
    // 原版的 `ctrl+l` 是 CompareLayer（比某一层），本仓「比某一层」= 换层，
    // 因此这里接它的**子集语义**：只留下「相比上一层改写过」的行。
    // 过滤放在 `TreeView` 上，动画序列里加了新键也不会把状态忘在别处。
    Action::FilterModified => {
      state.view.set_filter(Some(RowGroup::ModifiedOnly))
      return false
    }
    Action::FilterClear => {
      state.view.set_filter(None)
      return false
    }
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
    Action::ToggleCollapseAll => view.toggle_collapse_all()
    Action::None => ()
    // 上面已处理：这里再列一遍是为了让 `match` 穷尽，编译器会盯住新增动作
    Action::PrevLayer
    | Action::NextLayer
    | Action::NextFocus
    | Action::PrevFocus
    | Action::ToggleHelp
    | Action::ToggleSort
    | Action::CompareAll
    | Action::FilterModified
    | Action::FilterClear
    | Action::Quit => ()
  }
  false
}

///|
/// 画面上现在有没有详情面板。窄屏退化时它不存在（`Layout::compute` 会摘掉），
/// `Ctrl+A` 这类「以详情面板为承载面」的动作据此决定要不要理它。
///
/// 判据取**上一帧的布局**：与鼠标命中测试用的是同一份，
/// 因此 resize 之后还没重画时，两边看到的是同一版画面。
fn AppState::has_detail_pane(self : AppState) -> Bool {
  match self.last_layout {
    Some(layout) => layout.pane(PaneId::Detail) is Some(_)
    None => true
  }
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
