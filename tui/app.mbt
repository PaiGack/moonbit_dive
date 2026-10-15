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
    Some(self.views[layer].diff),
    layer,
    self.views.length(),
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
  // 换层后详情内容是新的，滚动位置归零，不然会停在一个没有意义的偏移上
  self.detail_scroll.to_top()
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
  let alt = AltScreen::new()
  alt.enter(tty)
  defer @async.protect_from_cancel(() => alt.leave(tty))
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
  let layout = Layout::compute(
    size.cols,
    size.rows,
    help_visible=state.help_visible,
  )
  // 翻页步长 = 主体可视行数 - 1，留一行重叠，翻页时不会漏行
  state.view.page_height = max(layout.body_height() - 1, 1)
  state.view.clamp_offset()
  state.detail_scroll.window = layout.body_height()
  state.detail_scroll.clamp()
  let screen = Screen::new(layout.cols, layout.rows)
  draw(screen, {
    layout,
    view: state.view,
    image: state.image,
    details: state.details,
    focus: state.focus,
    detail_scroll: state.detail_scroll,
    help_visible: layout.help_visible,
  })
  tty.with_synchronized_update(() => painter.paint(tty, screen))
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
