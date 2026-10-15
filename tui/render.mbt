///|
/// L2 画一帧。
///
/// 几何全部来自 `Layout`（分栏 + 边框 + 内容区），一块面板交给 `components.mbt`
/// 里的一个组件画；这一层只负责「按什么顺序画、画什么内容」。
///
/// 全屏形态下多了两件路径 A 没有的事：
///
/// - **焦点高亮**：谁聚焦，谁的框标题带 `>`（`paint_pane` 的 `focused`）
/// - **帮助浮层**：`frame.help_visible` 打开时盖在主体上，最后画（压在别的面板之上）
///
/// 「画什么」和「数据从哪来」仍然分开：视图状态（光标、折叠、层号）来自交互层，
/// 详情面板的数字来自 `image_analysis`。渲染函数只读这两份，不改动它们。
pub(all) struct Frame {
  layout : Layout
  view : TreeView
  /// 镜像名（标题行用）
  image : String
  /// 详情面板数据源；空表示没有分析结果
  details : DetailSource?
  /// 当前聚焦的面板
  mut focus : Focus
  /// 详情面板的滚动位置
  detail_scroll : Viewport
  /// 帮助浮层是否展开（`layout.help_visible` 已经收了「放不下」的情况）
  help_visible : Bool
} derive(Debug)

///|
/// 详情面板的数据源。
///
/// 用独立结构而不是直接塞 `image_analysis::Analysis`：渲染层不必知道
/// `image_analysis` 的内部布局，换数据源（逐层视图 / 效率报告）只要填这几个字段。
/// `DetailEntry` 里的 `cumulative` 是「各版本大小之和」，与报告里的
/// `wasted_bytes`（`cumulative - min`）不是同一个口径——这里只做展示，换算由数据源侧完成。
pub(all) struct DetailSource {
  /// 路径 → 写入记录
  entries : Map[String, DetailEntry]
  /// 被浪费的字节合计，口径是 `Σ (cumulative - min)`（dive 的 `inefficientBytes`）
  wasted : Int32
  /// 镜像内所有文件大小合计
  total : Int32
  /// efficiency 分数（0.0–1.0）
  efficiency : Double
  /// 多写了几份最多的路径，最多 10 条：`(path, versions, size)`
  ///
  /// 与 dive 详情面板下方那张 inefficient files 表同一批数字，
  /// 直接来自 `image_analysis::efficiency_view_rows`（精确的 `cumulative - min`），
  /// 不是「最终大小 × 版本数」那种近似。
  top_wasteful : Array[(String, Int32, Int32)]
} derive(Debug)

///|
/// 单条路径的详情。
pub(all) struct DetailEntry {
  /// 这个路径被写了几份
  versions : Int32
  /// 各版本大小之和
  cumulative : Int32
  /// 只留一份时需要的字节
  min_bytes : Int32
  /// 多写了几份：`cumulative - min`，与效率总分同一个口径的精确值
  ///
  /// 早先只有 `cumulative - min_bytes` 这个算式，且 `cumulative` 是
  /// 「最终大小 × 版本数」的**近似**（tar 层里没留历史大小），
  /// 于是算出来的 overhead 也只是近似。现在 `cumulative` 与 `min_bytes`
  /// 都来自逐路径版本表，`size` 因此是精确值（issue #72）。
  size : Int32
} derive(Eq, Debug)

///|
/// 画一整帧。
///
/// 顺序：标题行 → 两个主面板的框 → 主体内容 → 状态行 → 帮助浮层。
/// 框先画是因为内容只写内容区，不会盖住框；状态行最后保证它压在所有东西之上
/// （窄屏时主体可能与它重叠）。
pub fn draw(screen : Screen, frame : Frame) -> Unit {
  let layout = frame.layout
  draw_header(screen, layout, frame)
  // 框先立起来，内容区随后只动内部格子
  for pane in layout.panes {
    paint_pane(screen, pane, is_focused_pane(frame, pane.id))
  }
  draw_tree_pane(screen, layout, frame)
  draw_detail_pane(screen, layout, frame)
  draw_status_bar(screen, layout, frame)
  if frame.help_visible {
    draw_help(screen, layout, frame)
  }
}

///|
/// 该面板是不是当前焦点所在。
fn is_focused_pane(frame : Frame, id : PaneId) -> Bool {
  id == focus_pane_id(frame.focus)
}

///|
/// 标题行：左对齐镜像名，右对齐 `LAYER x/y`。
///
/// 全屏下标题行不画框（它只有一行），保持与状态行的对称。
fn draw_header(screen : Screen, layout : Layout, frame : Frame) -> Unit {
  screen.clear_row(layout.header_row)
  let mark = "LAYER \{frame.view.layer + 1}/\{frame.view.total_layers}"
  let mark_width = display_width(mark)
  if mark_width >= layout.cols {
    // 太窄就只放层号，别让标题把层号挤没
    screen.write_text(
      0,
      layout.header_row,
      truncate_to_width(mark, layout.cols),
    )
    return
  }
  let title_width = layout.cols - mark_width - 1
  let title = "dive  \{frame.image}"
  screen.write_text(0, layout.header_row, pad_to_width(title, title_width))
  screen.write_text(layout.cols - mark_width, layout.header_row, mark)
}

///|
/// 左栏：缩进的文件树。光标行左侧 `>`，目录行前带 `-`/`+`（展开/收起），
/// 右侧对齐大小（人类可读）与层号。
///
/// 光标行在**未聚焦**时不画 `>`（焦点在详情面板上时，树的高亮只是「上次停在哪」），
/// 用 `:` 顶替：既不丢掉位置感，也不装作还能操作。
fn draw_tree_pane(screen : Screen, layout : Layout, frame : Frame) -> Unit {
  let pane = match layout.pane(PaneId::Tree) {
    Some(pane) => pane
    None => return
  }
  clear_pane(screen, pane)
  let view = frame.view
  let width = pane.inner_width()
  let height = pane.inner_height()
  let (origin_col, origin_row) = (pane.inner_left(), pane.inner_top())
  let focused = frame.focus == Focus::Tree
  for row = 0; row < height; row = row + 1 {
    let index = view.offset + row
    if index < 0 || index >= view.visible.length() {
      continue
    }
    let item = view.visible[index]
    let selected = index == view.cursor
    screen.write_styled(
      origin_col,
      origin_row + row,
      format_row(item, view, width, selected, focused),
      row_style(item, selected),
    )
  }
  paint_overflow_hint(screen, pane, view.offset + height, view.visible.length())
}

///|
/// 行按 diff 类别上色：本层新增绿、改写黄、没动过的暗一档。
///
/// **光标行不换色**：光标位置已经由 `>` / `:` 标出来，再叠一层颜色只会让
/// 「光标在哪」和「这行是什么状态」互相盖住。看树时最常问的是「这一层动了哪些」，
/// 让颜色只回答这个问题。
///
/// 深色终端下 `BrightBlack` 是暗灰，浅色终端下它同样是「比正文轻」的那一档，
/// 因此不用去问终端默认背景色也能两端都成立。
fn row_style(item : Row, selected : Bool) -> Style {
  if selected {
    return style_default
  }
  match item.status {
    RowStatus::Added => style_added
    RowStatus::Modified => style_modified
    RowStatus::Unchanged => style_dim
  }
}

///|
/// 单行文本：`> ` + 缩进 + 折叠标记 + 名称 …… 右对齐 (大小) [Ln]。
fn format_row(
  item : Row,
  view : TreeView,
  width : Int32,
  selected : Bool,
  focused : Bool,
) -> String {
  let cursor = if !selected {
    " "
  } else if focused {
    ">"
  } else {
    // 焦点不在树上：光标行仍在，但不再宣称「按下去就动它」
    ":"
  }
  let tail = row_tail(item)
  let tail_width = display_width(tail)
  // 缩进按 path 的层级减一（根下第一层不缩进），每级两格
  let indent = spaces(max((item.depth - 1) * 2, 0))
  let marker = if item.is_dir {
    if view.collapsed.contains(item.path) {
      "+ "
    } else {
      "- "
    }
  } else {
    "  "
  }
  let name = @layer_tree.base_name(item.path)
  let lead = "\{cursor} \{indent}\{marker}"
  let lead_width = display_width(lead)
  // 名称与右侧尾巴之间留一格，不然 `main` 会和 `8.8 KB` 黏成 `main8.8 KB`。
  // 名称按预算右补空格（而不是只在超长时截断），尾巴才会被顶到最右边。
  let name_budget = max(width - lead_width - tail_width - 1, 1)
  let name = pad_to_width(truncate_to_width(name, name_budget), name_budget)
  pad_to_width("\{lead}\{name} \{tail}", width)
}

///|
/// 行尾：`(1.2 MB) [L2]`。目录不给大小，只给层号。
fn row_tail(item : Row) -> String {
  let layer = "[L\{item.layer}]"
  if item.is_dir {
    "\{layer} "
  } else {
    "\{human_size(item.size)} \{layer} "
  }
}

///|
/// 右栏：光标行的详情，按 `frame.detail_scroll` 滚动。
///
/// 没有数据源时给一行提示，不画半截面板；窄屏下这块面板不存在，直接跳过。
fn draw_detail_pane(screen : Screen, layout : Layout, frame : Frame) -> Unit {
  let pane = match layout.pane(PaneId::Detail) {
    Some(pane) => pane
    None => return
  }
  clear_pane(screen, pane)
  let source = match frame.details {
    Some(source) => source
    None => {
      screen.write_text(
        pane.inner_left(),
        pane.inner_top(),
        truncate_to_width(
          "(details unavailable: the analysis step failed)",
          pane.inner_width(),
        ),
      )
      return
    }
  }
  let path = frame.view.cursor_path_from_visible()
  let lines = match path {
    Some(path) => detail_lines(source, path)
    None => ["(no selection)"]
  }
  // 内容长度每帧会变（跟随光标），先把视口的计数对齐再取窗口
  frame.detail_scroll.set_content(lines.length())
  let height = pane.inner_height()
  let (origin_col, origin_row) = (pane.inner_left(), pane.inner_top())
  for row = 0; row < height; row = row + 1 {
    match frame.detail_scroll.line_at(row) {
      Some(index) => {
        let line = truncate_to_width(lines[index], pane.inner_width())
        screen.write_text(origin_col, origin_row + row, line)
      }
      None => ()
    }
  }
  paint_overflow_hint(
    screen,
    pane,
    frame.detail_scroll.offset + height,
    lines.length(),
  )
}

///|
/// 详情面板的文本行。
///
/// 面板分两段：上面是选中路径的账，下面是整镜像的 inefficient files 表
/// （dive 面板那三行概览 + 一张表的布局）。
fn detail_lines(source : DetailSource, path : String) -> Array[String] {
  let lines = [
    truncate_keep_tail(path, 200),
    "",
    "efficiency  \{percent_text(source.efficiency)}",
    "wasted      \{human_size(source.wasted)}",
    "total       \{human_size(source.total)}",
    "",
  ]
  match source.entries.get(path) {
    Some(entry) => {
      lines.push("versions    \{entry.versions}")
      lines.push("cumulative  \{human_size(entry.cumulative)}")
      lines.push("min         \{human_size(entry.min_bytes)}")
      if entry.size > 0 {
        lines.push("overhead    \{human_size(entry.size)}")
      } else {
        lines.push("overhead    -")
      }
    }
    // 目录本身不占体积（数据源只记文件），这里说明一句，别让读的人以为是缺数据
    None => lines.push("(no size record for this path)")
  }
  lines.push("")
  for line in ineffective_rows(source) {
    lines.push(line)
  }
  lines
}

///|
/// inefficient files 表的文本行（`count / total space / path`，dive 的列名）。
///
/// 表头与行都按列补齐：`truncate_to_width` 只在渲染时截断，
/// 这里补齐宽度是为了让「值 + 路径」两栏在终端里对齐。
fn ineffective_rows(source : DetailSource) -> Array[String] {
  let header = "count  total space  path"
  let rows = [header]
  if source.top_wasteful.is_empty() {
    rows.push("(none)")
    return rows
  }
  // 计数与体积各自右对齐到最宽的一行，路径跟着走
  let mut count_width = 5
  let mut space_width = 11
  for _, (_, _, size) in source.top_wasteful {
    let space = human_size(size)
    count_width = max(count_width, 2)
    space_width = max(space_width, display_width(space))
  }
  for _, (path, versions, size) in source.top_wasteful {
    let count = "x\{versions}"
    let space = human_size(size)
    rows.push(
      "\{pad_left_width(count, count_width)}  \{pad_left_width(space, space_width)}  \{truncate_keep_tail(path, 120)}",
    )
  }
  rows
}

///|
/// 按显示宽度左补空格到 `width` 列（数字列右对齐用）。
fn pad_left_width(text : String, width : Int32) -> String {
  let padding = width - display_width(text)
  if padding <= 0 {
    text
  } else {
    "\{spaces(padding)}\{text}"
  }
}

///|
/// 状态行：按键提示 + 焦点 + 光标位置 + diff 图例。
///
/// 提示随焦点变：焦点在详情面板时，↑↓ 滚的是详情，不是树。状态行**不画框**
/// （只有一行，画了就没内容了），所以这里直接 `clear_row`。
///
/// 右端自右向左依次占位：光标位置 → 图例 → 提示。图例（`+ add ~ change`）
/// 比提示优先级高——颜色本身不自解释，深浅终端上红/黄的观感还不一样，
/// 给一次字面说明比让人猜省事；提示被挤短了还能靠方向键试，图例没了就只能猜。
/// 两样都放不下时图例也舍掉，别让状态行看起来像被谁啃了一口。
fn draw_status_bar(screen : Screen, layout : Layout, frame : Frame) -> Unit {
  screen.clear_row(layout.status_row)
  let hint = match frame.focus {
    // 提示要短到能塞进 80 列的窄屏：`q quit` 被截掉时，
    // 用户最容易以为「退不出去」（鼠标提示在 `?` 的浮层里，见 `draw_help`）
    Focus::Tree =>
      "↑↓ move  click  ←→ fold  [ ] layer  s sort  Tab focus  ?  q quit"
    Focus::Detail => "↑↓ / wheel scroll  Tab focus  ?  q quit"
  }
  let order = if frame.view.sort_by_size { "size" } else { "name" }
  let position = if frame.view.visible.length() == 0 {
    "0/0 \{order}"
  } else {
    "\{frame.view.cursor + 1}/\{frame.view.visible.length()} \{order}"
  }
  let position_width = display_width(position)
  let position_start = layout.cols - position_width
  if position_width < layout.cols {
    screen.write_text(position_start, layout.status_row, position)
  }
  // 图例贴着光标位置左侧排；放不下就整块不画
  let legend_width = legend_width()
  let legend_start = position_start - 1 - legend_width
  let hint_limit = if legend_start <= 0 {
    position_start
  } else {
    draw_legend(screen, layout, legend_start)
    legend_start
  }
  screen.write_text(
    0,
    layout.status_row,
    truncate_to_width(hint, max(hint_limit - 1, 1)),
  )
}

///|
/// 图例的字面量与颜色：两组「符号 + 词」，颜色与树里的行一一对应。
///
/// 只列树里真会上色的两类：删除的路径已经不在树上，没有行可以标红，
/// 图例里放个永远不出现的 `- remove` 只会让人找它。
///
/// 单字母 + 一个词，是为了在 80 列里也放得下——写全 `added` / `modified`
/// 状态行就剩不下按键提示了。
fn legend_entries() -> Array[(String, Style)] {
  [("+ add", style_added), ("~ change", style_modified)]
}

///|
/// 图例整块占的列数（含段间空格）。
fn legend_width() -> Int32 {
  let mut width = 0
  for index, entry in legend_entries() {
    if index > 0 {
      width = width + legend_gap
    }
    width = width + display_width(entry.0)
  }
  width
}

///|
/// 段间空两格：颜色块之间要有视觉停顿，否则三段会连成一句看不懂的话。
let legend_gap : Int32 = 2

///|
/// 从 `start` 起画图例。
fn draw_legend(screen : Screen, layout : Layout, start : Int32) -> Unit {
  let mut col = start
  for index, entry in legend_entries() {
    if index > 0 {
      col = col + legend_gap
    }
    screen.write_styled(col, layout.status_row, entry.0, entry.1)
    col = col + display_width(entry.0)
  }
}

///|
/// 帮助浮层：一段固定说明，按面板高度截断。
///
/// 内容刻意短：浮层是「想不起来才看一眼」的东西，塞满一屏反而不想读。
/// 真正的键位表在 `tui/README.mbt.md`。
fn draw_help(screen : Screen, layout : Layout, frame : Frame) -> Unit {
  let pane = match layout.pane(PaneId::Help) {
    Some(pane) => pane
    None => return
  }
  clear_pane(screen, pane)
  let lines = [
    "↑↓ / j k       move or scroll", "←→ / h l       fold / unfold the tree",
    "PgUp / PgDn    page", "[ ]            previous / next layer", "Tab            switch focus (tree ↔ detail)",
    "?              toggle this panel", "q / Esc        quit", "click          select; on a folder also fold / unfold",
    "wheel          scroll the pane under the pointer", "right click    fold / unfold the row under the pointer",
    "s              sort by size (again: by name)",
  ]
  let height = pane.inner_height()
  let (origin_col, origin_row) = (pane.inner_left(), pane.inner_top())
  for index, line in lines {
    if index >= height {
      break
    }
    screen.write_text(
      origin_col,
      origin_row + index,
      truncate_to_width(line, pane.inner_width()),
    )
  }
  let _ = frame
}

///|
/// 人类可读的字节数：`512 B` / `1.2 KB` / `3.4 MB`。
///
/// 用 1024 进制：看镜像体积时 KB/MB 比 KiB/MiB 顺眼，且与 `dive` 原版的
/// 展示口径接近。只用于显示，不参与计算。
pub fn human_size(bytes : Int32) -> String {
  if bytes < 0 {
    return "0 B"
  }
  if bytes < 1024 {
    return "\{bytes} B"
  }
  let units = ["KB", "MB", "GB", "TB"]
  let mut value = bytes.to_double() / 1024.0
  let mut unit = 0
  while value >= 1024.0 && unit < units.length() - 1 {
    value = value / 1024.0
    unit = unit + 1
  }
  "\{format_one_decimal(value)} \{units[unit]}"
}

///|
/// 一位小数，且整数时不留 `.0`。
fn format_one_decimal(value : Double) -> String {
  let scaled = (value * 10.0).round().to_int()
  let whole = scaled / 10
  let fraction = scaled % 10
  if fraction == 0 {
    "\{whole}"
  } else {
    "\{whole}.\{fraction}"
  }
}

///|
/// 百分比文本：`0.873` → `87.3%`。
fn percent_text(value : Double) -> String {
  "\{format_one_decimal(value * 100.0)}%"
}

///|
/// 长名字保留尾部（比保留头部更有信息量：`/very/long/.../name.txt`）。
pub fn truncate_keep_tail(text : String, width : Int32) -> String {
  if width <= 0 {
    return ""
  }
  if display_width(text) <= width {
    return text
  }
  // 从尾部按 cluster 往回捡：cluster 是终端里的最小字形单位，
  // 半个 ZWJ 序列或半个组合字符留在开头，终端会把它当成一个新字形画出来。
  let clusters = graphemes(text).to_array()
  let mut kept = ""
  let mut used = 0
  let mut index = clusters.length() - 1
  while index >= 0 {
    let width_of = display_width(clusters[index])
    if used + width_of > width - 3 {
      break
    }
    kept = "\{clusters[index]}\{kept}"
    used = used + width_of
    index = index - 1
  }
  "...\{kept}"
}

///|
pub extend Frame with @debug.Debug::{to_repr}

///|
pub extend DetailSource with @debug.Debug::{to_repr}

///|
pub extend DetailEntry with Eq::{equal, not_equal}

///|
pub extend DetailEntry with @debug.Debug::{to_repr}
