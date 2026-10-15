///|
/// 交互式看树的主循环。
///
/// 这一层只做三件事：拿终端尺寸 → 组装 `Frame` → 等一次事件。
/// 「事件怎么变成新的视图状态」在 `keys.mbt`，「画面怎么拼」在 `render.mbt`，
/// 都从数据源解耦，方便单测。
///
/// 形态是**非全屏**（路径 A）：直接占主屏，底部一行状态条，
/// 不切 alternate screen、不做分栏布局引擎。退出后终端恢复到进入前的样子
/// （raw mode 由 `with_raw_mode` 兜住）。
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
  let tree = if views.length() > 0 {
    views[layer].tree
  } else {
    @layer_tree.FileTree::new()
  }
  let view = TreeView::from_tree(tree, layer, views.length())
  { views, details, image, view, }
}

///|
/// 换到第 `layer` 层：重建视图状态，保留当前光标路径（换层后尽量停在同一文件上）。
pub fn AppState::switch_layer(self : AppState, layer : Int32) -> Unit {
  if layer < 0 || layer >= self.views.length() {
    return
  }
  let keep = self.view.cursor_path_from_visible()
  let view = TreeView::from_tree(
    self.views[layer].tree,
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
}

///|
/// 主循环：读到退出键、或输入被关闭时结束。
///
/// `esc_timeout_ms` 是 ESC 与后续字节拼帧的等待窗口（tty 层的 `read_event` 参数）。
/// 给 50ms：够终端把 `\\x1b[A`（方向键）拼完，又不会让单按 ESC 明显卡顿。
pub async fn run_app(tty : @tty.Tty, state : AppState) -> Unit {
  let painter = Painter::new()
  tty.hide_cursor()
  defer @async.protect_from_cancel(() => cleanup(tty))
  loop_draw(tty, painter, state)
  while true {
    let event = tty.read_event(esc_timeout_ms~) catch {
      @async/io.ReaderClosed => break
      _ => break
    }
    let mut quit = false
    match event {
      @tty.Event::Input(@input.InputEvent::Key(key)) => {
        let action = action_of_key(key)
        quit = apply_action(action, state.view, layer => {
          state.switch_layer(layer)
        })
      }
      @tty.Event::Input(_) => ()
      @tty.Event::Resize(_) => ()
    }
    if quit {
      break
    }
    loop_draw(tty, painter, state)
  }
}

///|
/// 画一帧：按当前终端尺寸重算布局，回填翻页步长，然后交给 painter。
async fn loop_draw(tty : @tty.Tty, painter : Painter, state : AppState) -> Unit {
  let size = window_size(tty)
  let layout = Layout::compute(size.cols, size.rows)
  // 翻页步长 = 主体可视行数 - 1，留一行重叠，翻页时不会漏行
  state.view.page_height = max(layout.body_height() - 1, 1)
  state.view.clamp_offset()
  let screen = Screen::new(layout.cols, layout.rows)
  draw(screen, {
    layout,
    view: state.view,
    image: state.image,
    details: state.details,
  })
  tty.with_synchronized_update(() => painter.paint(tty, screen))
}

///|
/// 退出时恢复光标，并把状态行留在最后一行。
async fn cleanup(tty : @tty.Tty) -> Unit {
  tty.show_cursor()
  tty.write_string("\r\n")
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
