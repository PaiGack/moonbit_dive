///|
/// L4 主循环。
///
/// 这一层只做四件事：拿终端尺寸 → 组装 `Frame` → 等一次事件 → 把动作施加回状态。
/// 「事件怎么变成新的视图状态」在 `keys.mbt`，「画面怎么拼」在 `render.mbt`，
/// 「终端生命周期」在 `alt_screen.mbt`，都从数据源解耦，方便单测。
///
/// 形态是**全屏**（路径 B）：进 alternate screen，画带边框的分栏，退出时还原。
/// 还原走两层保护：
///
/// 1. tty 的 `with_raw_mode` / 我们自己的 `defer` 管「异常也要还原」
/// 2. `AltScreen::leave` 是幂等的，`enter` 抛了错也能安全 `leave`
///
/// 每帧在 `with_synchronized_update` 里下发：终端会把这一批字节当一次原子刷新，
/// 避免逐字节下发时的撕裂。
///
/// 输入有两条：键盘（`keys.mbt`）与鼠标（`./mouse.mbt`）。鼠标多一层坐标，
/// 得先按 `Layout` 认出「点在哪个面板的哪一行」，这一段收在 `handle_mouse`。
pub(all) struct AppState {
  /// 逐层视图，`[i]` 是应用完第 i 层之后的树
  views : Array[@layer_tree.LayerView]
  /// 详情数据源（体积/浪费/效率）
  details : DetailSource?
  /// 镜像名
  image : String
  /// 当前视图
  mut view : TreeView
  /// 当前焦点
  mut focus : Focus
  /// 详情面板的滚动位置
  detail_scroll : Viewport
  /// 帮助浮层是否展开
  mut help_visible : Bool
  /// 删除列表浮层是否展开（聚合档下 `removed` 可能有几百条，单独给一张列表）
  mut removed_visible : Bool
  /// 删除列表的滚动位置
  removed_scroll : Viewport
  /// 上一帧的布局；鼠标事件要用它把屏幕坐标换成面板 + 行号。
  ///
  /// 存下来而不是**重新算**：算布局要终端尺寸，而鼠标事件处理是同步的、
  /// 拿不到 async 的 `window_size`。画帧时顺手记一份，坐标口径天然一致
  /// （哪怕 resize 之后还没重画，用的也是画面上那一版真实布局）。
  mut last_layout : Layout?
} derive(Debug)

///|
/// 从逐层视图与分析结果建状态。光标从第 0 行开始。
pub fn AppState::new(
  views : Array[@layer_tree.LayerView],
  details : DetailSource?,
  image : String,
  initial_layer~ : Int32 = 0,
) -> AppState {
  let layer = clamp(initial_layer, 0, max(views.length() - 1, 0))
  // 没有层（空镜像）时给一棵空树：视图逻辑本身不需要「至少有一层」这个前提
  let view = if views.length() > 0 {
    TreeView::from_tree_with_diff(
      views[layer].tree,
      Some(views[layer].diff),
      layer,
      views.length(),
      false,
    )
  } else {
    TreeView::from_tree(@layer_tree.FileTree::new(), layer, 0)
  }
  {
    views,
    details,
    image,
    view,
    focus: Focus::Tree,
    detail_scroll: Viewport::new(0, 1),
    help_visible: false,
    removed_visible: false,
    removed_scroll: Viewport::new(0, 1),
    last_layout: None,
  }
}

///|
/// 换到第 `layer` 层：重建视图状态，保留当前光标路径（换层后尽量停在同一文件上）。
pub fn AppState::switch_layer(self : AppState, layer : Int32) -> Unit {
  if layer < 0 || layer >= self.views.length() {
    return
  }
  let keep = self.view.cursor_path_from_visible()
  let view = TreeView::from_tree_with_diff(
    self.views[layer].tree,
    Some(diff_for(self.views[layer], self.view.compare_mode)),
    layer,
    self.views.length(),
    self.view.sort_by_size,
    compare_mode=self.view.compare_mode,
  )
  match keep {
    Some(path) =>
      match view.index_of_path(path) {
        Some(index) => view.move_to(index)
        None => ()
      }
    None => ()
  }
  self.view = view
  self.removed_scroll.to_top()
  // 换层后详情内容是新的，滚动位置归零，不然会停在一个没有意义的偏移上
  self.detail_scroll.to_top()
}

///|
/// 当前档位下给行上色用的 diff：单层档用逐层 diff，聚合档用聚合 diff。
///
/// 树只有一棵，换档位换的就是这里——「树形状不变、只有 diff 标注变」。
fn diff_for(
  view : @layer_tree.LayerView,
  mode : CompareMode,
) -> @layer_tree.Diff {
  match mode {
    Single => view.diff
    Aggregate => view.aggregate
  }
}

///|
/// 切换比较档位（`Ctrl+A` 聚合 / `Ctrl+L` 当前层）。
///
/// 重建视图但不换数据源：树、光标路径、折叠状态都留着，只有行上的颜色与
/// 删除列表跟着换——这正是原版 dive 切档位的观感（`GetCompareIndexes` 只换下标）。
pub fn AppState::switch_compare_mode(
  self : AppState,
  mode : CompareMode,
) -> Unit {
  if self.view.compare_mode == mode {
    return
  }
  let layer = self.view.layer
  let keep = self.view.cursor_path_from_visible()
  let view = TreeView::from_tree_with_diff(
    self.views[layer].tree,
    Some(diff_for(self.views[layer], mode)),
    layer,
    self.views.length(),
    self.view.sort_by_size,
    compare_mode=mode,
  )
  view.collapsed = self.view.collapsed
  view.refresh()
  match keep {
    Some(path) =>
      match view.index_of_path(path) {
        Some(index) => view.move_to(index)
        None => ()
      }
    None => ()
  }
  self.view = view
  self.removed_scroll.to_top()
}

///|
/// 删除列表的内容：单层档给这一层的 `removed`，聚合档给整段区间的 `removed`。
pub fn AppState::removed_paths(self : AppState) -> Array[String] {
  self.view.removed.copy()
}

///|
/// 开关删除列表浮层；关上时滚动位置归零。
pub fn AppState::toggle_removed(self : AppState) -> Unit {
  self.removed_visible = !self.removed_visible
  if !self.removed_visible {
    self.removed_scroll.to_top()
  }
}

///|
/// 切换排序口径（名字 / 大小）并重建当前层的行。
///
/// 为什么要回数据源重建，而不是在 `TreeView` 里就地重排：拍平后的行带着
/// `depth`，折叠过滤靠「祖先在不在」判断——`all_rows` 一旦乱序，
/// `nearest_visible` 的「就近落点」就失去意义（它默认数组是按路径有序的）。
/// 所以排序在**源头**（`FileTree` 的遍历顺序）里做，视图只是重新拍一遍。
///
/// 换层时 `switch_layer` 会重建视图，排序口径得跟着走——`TreeView` 自己
/// 存着 `sort_by_size`，重建后由这里再套一次。
pub fn AppState::toggle_sort(self : AppState) -> Unit {
  let by_size = !self.view.sort_by_size
  let layer = self.view.layer
  let keep = self.view.cursor_path_from_visible()
  let view = TreeView::from_tree_with_diff(
    self.views[layer].tree,
    Some(diff_for(self.views[layer], self.view.compare_mode)),
    layer,
    self.views.length(),
    by_size,
    compare_mode=self.view.compare_mode,
  )
  match keep {
    Some(path) =>
      match view.index_of_path(path) {
        Some(index) => view.move_to(index)
        None => ()
      }
    None => ()
  }
  self.view = view
}

///|
/// 主循环：读到退出键、或输入被关闭时结束。
///
/// `esc_timeout_ms` 是 ESC 与后续字节拼帧的等待窗口（tty 层的 `read_event` 参数）。
/// 给 50ms：够终端把 `\\x1b[A`（方向键）拼完，又不会让单按 ESC 明显卡顿。
///
/// 全屏的进出都在这里：进之前先 `enter`（进不去就抛，让调用方报错而不是
/// 把画面画到主屏上），退出走 `defer`，因此 panic / 取消 / 正常读到 `q`
/// 三条路都会还原终端。
pub async fn run_app(tty : @tty.Tty, state : AppState) -> Unit {
  let painter = Painter::new()
  let size = window_size(tty)
  let alt = AltScreen::new()
  alt.enter(tty)
  defer @async.protect_from_cancel(() => alt.leave(tty))
  // 鼠标跟踪（#51）由这一对 defer 管，不进 `enter_commands` / `teardown_commands`：
  // 「关掉鼠标」在 tty 里是一串独立的模式位（`disable_mouse`），不是一条 `Command`。
  // 两个 defer 的顺序与进出全屏对称：开在进屏之后，关在离屏之前——
  // 鼠标跟踪是全局的，漏关掉会让退出后的 shell 把每次点击吐成 `\x1b[<...` 垃圾。
  //
  // 模式取见 `mouse_tracking_mode`（#62）：`Drag` 比 #51 的 `Click` 多一档
  // 「按住移动」。像素坐标的 kitty 鼠标报告由 `resolve_mouse` 兜底换算回格子，
  // 不再像 tty 0.5.0 那样静默 `Unknown` 丢掉。
  tty.enable_mouse(mouse_tracking_mode(pixel_mouse=false))
  defer @async.protect_from_cancel(() => tty.disable_mouse())
  draw_frame(tty, painter, state)
  while true {
    let event = tty.read_event(esc_timeout_ms~) catch {
      @async/io.ReaderClosed => break
      _ => break
    }
    let mut quit = false
    match event {
      @tty.Event::Input(@input.InputEvent::Key(key)) => {
        let action = action_of_key(key)
        quit = apply_action(action, state)
      }
      @tty.Event::Input(@input.InputEvent::Mouse(mouse)) => {
        // 像素口径 → 格子口径（#62）；普通终端原样返回
        let mouse = resolve_mouse(mouse, size.cols, size.rows)
        quit = handle_mouse(mouse, state)
      }
      @tty.Event::Input(_) => ()
      @tty.Event::Resize(_) => ()
    }
    if quit {
      break
    }
    draw_frame(tty, painter, state)
  }
}

///|
/// 画一帧：按当前终端尺寸重算布局，回填翻页步长，然后交给 painter。
async fn draw_frame(
  tty : @tty.Tty,
  painter : Painter,
  state : AppState,
) -> Unit {
  let size = window_size(tty)
  // 帮助与删除列表共用同一块浮层位置（不会同时开），标题按当前那块给
  let overlay = state.removed_visible || state.help_visible
  let layout = Layout::compute(
    size.cols,
    size.rows,
    help_visible=overlay,
    overlay_title=if state.removed_visible { "removed paths" } else { "keys" },
  )
  // 翻页步长 = 主体可视行数 - 1，留一行重叠，翻页时不会漏行
  state.view.page_height = max(layout.body_height() - 1, 1)
  // 鼠标的坐标反查要用「画面上那一版」布局，与渲染共用同一份
  state.last_layout = Some(layout)
  state.view.clamp_offset()
  state.detail_scroll.window = layout.body_height()
  state.detail_scroll.clamp()
  state.removed_scroll.window = match layout.pane(PaneId::Help) {
    Some(pane) => pane.inner_height()
    None => 1
  }
  state.removed_scroll.clamp()
  let screen = Screen::new(layout.cols, layout.rows)
  draw(screen, {
    layout,
    view: state.view,
    image: state.image,
    details: state.details,
    focus: state.focus,
    detail_scroll: state.detail_scroll,
    help_visible: layout.help_visible,
    removed_visible: layout.help_visible && state.removed_visible,
    removed: state.removed_paths(),
    removed_scroll: state.removed_scroll,
  })
  tty.with_synchronized_update(() => painter.paint(tty, screen))
}

///|
/// 把一次鼠标事件落到「哪个面板、哪一行」，再施加到状态上。
///
/// 坐标的两次换算都在这里：
///
/// 1. **绝对坐标 → 面板**：`Layout` 的矩形是屏幕绝对坐标（`.row` / `.col`
///    是 1 起的终端格），先减 1 换算成 0 起，再看落在哪块面板里
/// 2. **面板内相对行 → 可见行下标**：交给 `TreeView::index_at_screen_row`
///    或 `Viewport`，它们是画帧时用的同一份 `offset`
///
/// 点空白和点面板外都不动状态：坐标对不上就是「这一下没打中」，
/// 夹到首行/末行反而像凭空跳了一下。
///
/// 返回是否要退出主循环——鼠标本身不能退出，这个返回值留给以后
/// 可能加的中键/手势，签名与键盘那侧保持一致。
pub fn handle_mouse(event : @input.MouseEvent, state : AppState) -> Bool {
  let action = action_of_mouse(event)
  if action == MouseAction::None {
    return false
  }
  // 帮助浮层开着时，鼠标与键盘一个口径：先关掉再说，
  // 不然点到的是浮层底下那块看不见的面板
  if state.help_visible {
    if action == MouseAction::Select || action == MouseAction::SetFocus {
      return false
    }
  }
  let size = state.last_layout
  let target = match size {
    Some(layout) => hit_test(layout, event.row, event.col)
    None => None
  }
  let (pane_id, row_in_pane) = match target {
    Some(target) => target
    None => return false
  }
  match action {
    MouseAction::Select =>
      // 选中成功才跟着切焦点：点面板里的空白格既不该选行，
      // 也不该把键盘焦点从原处夺走（详情面板没有「行」，
      // 点到内容区即视为有效）
      if pane_id == PaneId::Tree {
        // 左键点目录行顺带切展开态（#62）：与键盘 `Enter` 对称，
        // 右键的老手感照旧。文件行只落光标——`toggle_fold_at_screen_row`
        // 里的 `toggle` 对非目录行是空操作，两种行因此共用一段代码
        if state.view.toggle_fold_at_screen_row(row_in_pane) {
          state.focus = Focus::Tree
        }
      } else if pane_id == PaneId::Detail {
        state.focus = Focus::Detail
      }
    MouseAction::SetFocus =>
      match pane_id {
        PaneId::Tree => state.focus = Focus::Tree
        PaneId::Detail => state.focus = Focus::Detail
        _ => ()
      }
    MouseAction::ToggleFold =>
      if pane_id == PaneId::Tree {
        state.focus = Focus::Tree
        ignore(state.view.toggle_fold_at_screen_row(row_in_pane))
      }
    MouseAction::ScrollUp =>
      // 滚轮按面板分派：树滚光标，详情滚视口——与键盘的焦点规则一致，
      // 但滚轮不需要先切焦点，鼠标停在哪块就滚哪块
      if pane_id == PaneId::Tree {
        state.view.move_to(state.view.cursor - scroll_step())
      } else if pane_id == PaneId::Detail {
        state.detail_scroll.scroll_by(-scroll_step())
      }
    MouseAction::ScrollDown =>
      if pane_id == PaneId::Tree {
        state.view.move_to(state.view.cursor + scroll_step())
      } else if pane_id == PaneId::Detail {
        state.detail_scroll.scroll_by(scroll_step())
      }
    MouseAction::None => ()
  }
  false
}

///|
/// 坐标落在哪块面板的哪一行：返回 `(面板 id, 面板内容区内的相对行)`。
///
/// `row` / `col` 是终端格的 1 起坐标（tty 的口径），这里换成 0 起。
/// 只有带内容区的面板（树 / 详情）参与命中：状态行与帮助浮层没有可点的行。
pub fn hit_test(layout : Layout, row : Int32, col : Int32) -> (PaneId, Int32)? {
  let (row, col) = (row - 1, col - 1)
  if row < 0 || col < 0 {
    return None
  }
  let panes : Array[PaneId] = [PaneId::Tree, PaneId::Detail]
  for id in panes {
    match layout.pane(id) {
      Some(pane) => {
        let rect = pane.rect
        if rect.width() == 0 || rect.height() == 0 {
          continue
        }
        // 命中判定用**外框**：点边框那一格也算点这块面板，
        // 用内容区判定会让边框变成一条「点不动」的缝
        if col < rect.left || col > rect.right {
          continue
        }
        if row < rect.top || row > rect.bottom {
          continue
        }
        return Some((id, row - pane.inner_top()))
      }
      None => ()
    }
  }
  None
}

///|
/// ESC 拼帧的等待窗口（毫秒）。见 `run_app` 注释。
let esc_timeout_ms : Int32 = 50

///|
/// 取终端尺寸；拿不到时退到 80x24（经典默认），不让画面逻辑处理错误。
pub fn window_size(tty : @tty.Tty) -> WindowSize {
  try tty.window_size() catch {
    _ => { cols: 80, rows: 24, }
  } noraise {
    size =>
      {
        cols: if size.cols < 1 {
          80
        } else {
          size.cols
        },
        rows: if size.rows < 1 {
          24
        } else {
          size.rows
        },
      }
  }
}

///|
/// 终端尺寸（本地类型，避免在渲染层依赖 `@tty`）。
pub(all) struct WindowSize {
  cols : Int32
  rows : Int32
} derive(Eq, Debug)

///|
pub extend AppState with @debug.Debug::{to_repr}

///|
pub extend WindowSize with Eq::{equal, not_equal}

///|
pub extend WindowSize with @debug.Debug::{to_repr}
