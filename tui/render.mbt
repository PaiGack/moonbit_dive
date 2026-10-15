///|
/// 一帧要画的内容：布局 + 视图状态 + 数据源。
///
/// 把「画什么」和「数据从哪来」分开：视图状态（光标、折叠、层号）来自交互层，
/// 详情面板的数字来自 `image_analysis`。渲染函数只读这两份，不改动它们。
pub(all) struct Frame {
  layout : Layout
  view : TreeView
  /// 镜像名（标题行用）
  image : String
  /// 详情面板数据源；空表示没有分析结果
  details : DetailSource?
} derive(Debug)

///|
/// 详情面板的数据源。
///
/// 用独立结构而不是直接塞 `image_analysis::Analysis`：渲染层不必知道
/// `image_analysis` 的内部布局，换数据源（逐层视图 / 效率报告）只要填这几个字段。
/// 注意 `cumulative_bytes` 是「各版本大小之和」，与报告里的 `wasted_bytes`
/// 不是同一个口径——这里只做展示，换算由数据源侧完成。
pub(all) struct DetailSource {
  /// 路径 → 写入记录
  entries : Map[String, DetailEntry]
  /// 被浪费的字节合计
  wasted : Int32
  /// 镜像内所有文件大小合计
  total : Int32
  /// efficiency 分数（0.0–1.0）
  efficiency : Double
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
} derive(Eq, Debug)

///|
/// 画一整帧。
pub fn draw(screen : Screen, frame : Frame) -> Unit {
  let layout = frame.layout
  draw_header(screen, layout, frame)
  draw_tree_pane(screen, layout, frame.view)
  draw_detail_pane(screen, layout, frame)
  draw_status_bar(screen, layout, frame)
}

///|
/// 标题行：左对齐镜像名，右对齐 `LAYER x/y`。
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
fn draw_tree_pane(screen : Screen, layout : Layout, view : TreeView) -> Unit {
  let width = layout.left_width()
  let height = layout.body_height()
  for row = 0; row < height; row = row + 1 {
    let screen_row = layout.body_top + row
    screen.clear_row(screen_row)
    let index = view.offset + row
    if index < 0 || index >= view.visible.length() {
      continue
    }
    let item = view.visible[index]
    let selected = index == view.cursor
    screen.write_text(0, screen_row, format_row(item, view, width, selected))
  }
  // 可视区放不下时在右下角提示还有多少行
  if view.visible.length() > height && height > 0 {
    let hint = "\{view.offset + height}/\{view.visible.length()}"
    let hint_width = display_width(hint)
    if hint_width < width {
      screen.write_text(width - hint_width, layout.body_top + height - 1, hint)
    }
  }
}

///|
/// 单行文本：`> ` + 缩进 + 折叠标记 + 名称 …… 右对齐 (大小) [Ln]。
fn format_row(
  item : Row,
  view : TreeView,
  width : Int32,
  selected : Bool,
) -> String {
  let cursor = if selected { ">" } else { " " }
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
/// 右栏：光标行的详情。没有数据源时给一行提示，不画半截面板。
fn draw_detail_pane(screen : Screen, layout : Layout, frame : Frame) -> Unit {
  if layout.right_start < 0 {
    return
  }
  let top = layout.body_top
  let height = layout.body_height()
  let width = layout.right_width()
  // 只清右栏那几列：`clear_row` 会把左栏的树一起擦掉
  for row = 0; row < height; row = row + 1 {
    for col = layout.right_start; col <= layout.right_end; col = col + 1 {
      screen.set(col, top + row, ' ')
    }
  }
  let source = match frame.details {
    Some(source) => source
    None => return
  }
  let path = frame.view.cursor_path_from_visible()
  let lines = match path {
    Some(path) => detail_lines(source, path)
    None => ["(no selection)"]
  }
  for index, line in lines {
    if index >= height {
      break
    }
    screen.write_text(
      layout.right_start,
      top + index,
      truncate_to_width(line, width),
    )
  }
}

///|
/// 详情面板的文本行。
fn detail_lines(source : DetailSource, path : String) -> Array[String] {
  let lines = [
    truncate_to_width(path, 200),
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
      let overhead = entry.cumulative - entry.min_bytes
      if overhead > 0 {
        lines.push("overhead    \{human_size(overhead)}")
      } else {
        lines.push("overhead    -")
      }
    }
    // 目录本身不占体积（数据源只记文件），这里说明一句，别让读的人以为是缺数据
    None => lines.push("(no size record for this path)")
  }
  lines
}

///|
/// 状态行：按键提示 + 光标位置。
fn draw_status_bar(screen : Screen, layout : Layout, frame : Frame) -> Unit {
  screen.clear_row(layout.status_row)
  let hint = "↑↓ move  ←→ fold  [ ] layer  q quit"
  let position = if frame.view.visible.length() == 0 {
    "0/0"
  } else {
    "\{frame.view.cursor + 1}/\{frame.view.visible.length()}"
  }
  let position_width = display_width(position)
  screen.write_text(
    0,
    layout.status_row,
    truncate_to_width(hint, max(layout.cols - position_width - 1, 1)),
  )
  if position_width < layout.cols {
    screen.write_text(layout.cols - position_width, layout.status_row, position)
  }
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
  let chars = text.to_array()
  let mut kept = String::make(0, ' ')
  let mut used = 0
  let mut index = chars.length() - 1
  while index >= 0 {
    let width_of = char_width(chars[index])
    if used + width_of > width - 3 {
      break
    }
    kept = "\{chars[index]}\{kept}"
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
