///|
/// 建一棵树 + 视图，供渲染测试复用。
fn render_fixture() -> (Screen, Frame) {
  let tree = @layer_tree.FileTree::new()
  let tar = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
    @layer_tree.TarEntrySpec::File("etc/passwd", "root:x"),
  ])
  @layer_tree.apply_layer(tree, tar, 0) catch {
    err => abort(err.to_string())
  }
  let view = TreeView::from_tree(tree, 0, 3)
  let layout = Layout::compute(80, 24)
  let screen = Screen::new(layout.cols, layout.rows)
  (
    screen,
    {
      layout,
      view,
      image: "demo:latest",
      details: None,
      focus: Focus::Tree,
      detail_scroll: Viewport::new(0, 1),
      help_visible: false,
    },
  )
}

///|
/// 标题行有镜像名，右侧有层号。
test "draw paints the header with image and layer" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  let header = screen.row_string(0)
  assert_true(header.contains("dive"))
  assert_true(header.contains("demo:latest"))
  assert_true(header.contains("LAYER 1/3"))
}

///|
/// 状态行在最后一行，右侧是光标位置。
test "draw paints the status bar" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  let status = screen.row_string(23)
  // 提示右端可能被图例挤掉，开头与右侧的位置计数一定在
  assert_true(status.contains("move"))
  assert_true(status.contains("1/3"))
  // 排序口径跟着光标位置一起显示（#51 的 `s` 键）
  assert_true(status.contains("name"))
}

///|
/// 树行带缩进、名称与层号；光标行以 `>` 起头。
test "draw paints tree rows with cursor and layer" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  // 树的内容区从第 2 行（0 起）起笔：第 1 行是上边框
  let body = screen.row_string(2)
  assert_true(body.contains("> "))
  // 行显示的是 basename（路径层级靠缩进表达）
  assert_true(body.contains("etc"))
  assert_true(body.contains("[L0]"))
}

///|
/// 目录行前带折叠标记：展开是 `-`。
test "draw marks expanded directories" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  let body = screen.row_string(2)
  assert_true(body.contains("- etc"))
}

///|
/// 没有详情数据源时右栏给一行提示，不画半截面板。
test "draw explains a missing detail source instead of leaving it blank" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  // 右栏内容区第一行（列 42，行 2：框占了外圈）
  let row = screen.row_string(2)
  assert_true(row[42:].contains("details unavailable"))
}

///|
/// 有详情源时右栏出效率与浪费信息。
test "draw paints the detail pane with a source" {
  let (screen, base) = render_fixture()
  let entries : Map[String, DetailEntry] = Map([])
  entries.set("/etc/hosts", { versions: 2, cumulative: 200, min_bytes: 100, })
  let source : DetailSource = {
    entries,
    wasted: 4096,
    total: 8192,
    efficiency: 0.5,
  }
  draw(screen, { ..base, details: Some(source), })
  // 右栏区域应出现 efficiency 字样
  let mut found = false
  for row = 1; row < 23; row = row + 1 {
    let line = screen.row_string(row)
    let right = line[41:].to_owned()
    if right.contains("efficiency") {
      found = true
    }
  }
  assert_true(found)
}

///|
/// 光标落到有写记录的路径上时，右栏出这份记录。
test "draw shows the size record for the selected path" {
  let (screen, base) = render_fixture()
  let entries : Map[String, DetailEntry] = Map([])
  entries.set("/etc/hosts", { versions: 3, cumulative: 300, min_bytes: 100, })
  let source : DetailSource = {
    entries,
    wasted: 200,
    total: 8192,
    efficiency: 0.9,
  }
  base.view.move_to(base.view.index_of_path("/etc/hosts").unwrap())
  draw(screen, { ..base, details: Some(source), })
  let mut joined = ""
  for row = 1; row < 23; row = row + 1 {
    joined = joined + screen.row_string(row)
  }
  assert_true(joined.contains("versions"))
  assert_true(joined.contains("overhead"))
}

///|
/// 人类可读字节数。
test "human_size formats bytes" {
  assert_eq(human_size(0), "0 B")
  assert_eq(human_size(512), "512 B")
  assert_eq(human_size(1024), "1 KB")
  assert_eq(human_size(1536), "1.5 KB")
  assert_eq(human_size(1024 * 1024), "1 MB")
  assert_eq(human_size(-1), "0 B")
}

///|
/// 尾部截断保留结尾，前面加省略号。
test "truncate_keep_tail keeps the tail" {
  let text = "/very/long/path/to/some/file.txt"
  let cut = truncate_keep_tail(text, 12)
  assert_true(cut.has_prefix("..."))
  assert_true(cut.contains("file.txt"))
  assert_true(display_width(cut) <= 12)
  assert_eq(truncate_keep_tail("short", 20), "short")
}

///|
/// 名称与右侧的大小/层号之间要有空格，否则读起来会黏成一个词。
test "draw keeps a gap between the name and the size tail" {
  let tree = @layer_tree.FileTree::new()
  let tar = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "x"),
  ])
  @layer_tree.apply_layer(tree, tar, 0) catch {
    err => abort(err.to_string())
  }
  let view = TreeView::from_tree(tree, 0, 1)
  let layout = Layout::compute(60, 10)
  let screen = Screen::new(layout.cols, layout.rows)
  draw(screen, {
    layout,
    view,
    image: "demo",
    details: None,
    focus: Focus::Tree,
    detail_scroll: Viewport::new(0, 1),
    help_visible: false,
  })
  // `main` 与 `1 B` 之间是补齐的空格，不是直接相连
  let body = screen.row_string(3)
  assert_true(body.contains("main"))
  assert_true(body.contains("1 B [L0]"))
  assert_false(body.contains("main1 B"))
  // 行的首列是内容（不是边框）：单栏左侧边框在列 0，内容从列 1 起
  assert_eq(screen.get(0, 2), "|")
}

///|
/// 聚焦面板的框标题带 `>`，未聚焦的没有。
test "draw marks the focused pane in the border title" {
  let (screen, base) = render_fixture()
  draw(screen, base)
  assert_true(screen.row_string(1).contains(">files"))
  assert_false(screen.row_string(1).contains(">layer detail"))
  base.focus = Focus::Detail
  draw(screen, base)
  assert_false(screen.row_string(1).contains(">files"))
  assert_true(screen.row_string(1).contains(">layer detail"))
}

///|
/// 焦点不在树上时，光标行不再用 `>`，改用 `:`——位置仍在，但不装作还能操作。
test "draw keeps the cursor row visible when the tree loses focus" {
  let (screen, base) = render_fixture()
  base.focus = Focus::Detail
  draw(screen, base)
  let row = screen.row_string(2)
  assert_false(row.contains("> "))
  // 行首是空格 + 光标列，`:` 表示「上次停在这」
  assert_true(row.contains(": "))
}

///|
/// 状态行提示随后焦点变化：焦点在详情面板上时说的是「滚动」。
test "draw hints the keys of the focused pane" {
  let (screen, base) = render_fixture()
  draw(screen, base)
  assert_true(screen.row_string(23).contains("fold"))
  base.focus = Focus::Detail
  draw(screen, base)
  let status = screen.row_string(23)
  assert_true(status.contains("scroll"))
  assert_false(status.contains("fold"))
}

///|
/// 帮助浮层展开时铺在主体下半部分，并且盖住树的内容。
test "draw paints the help overlay above the panes" {
  let (screen, base) = render_fixture()
  let layout = Layout::compute(80, 24, help_visible=true)
  let help_pane = layout.pane(PaneId::Help).unwrap()
  let frame : Frame = { ..base, layout, help_visible: true, }
  draw(screen, frame)
  let mut joined = ""
  for row = help_pane.rect.top; row <= help_pane.rect.bottom; row = row + 1 {
    joined = joined + screen.row_string(row)
  }
  assert_true(joined.contains("switch focus"))
  assert_true(joined.contains("toggle this panel"))
  // 浮层自带边框（标题 `keys`）
  assert_true(joined.contains("keys"))
}

///|
/// 详情面板的滚动：滚下去之后第一行不再是路径。
test "draw scrolls the detail pane" {
  let (screen, base) = render_fixture()
  let entries : Map[String, DetailEntry] = Map([])
  entries.set("/etc/hosts", { versions: 2, cumulative: 200, min_bytes: 100, })
  let source : DetailSource = {
    entries,
    wasted: 4096,
    total: 8192,
    efficiency: 0.5,
  }
  base.view.move_to(base.view.index_of_path("/etc/hosts").unwrap())
  let frame : Frame = { ..base, details: Some(source), }
  draw(screen, frame)
  // 光标停在 `/etc/hosts`，详情首行是路径
  assert_true(screen.row_string(2)[42:].contains("/etc/hosts"))
  // 滚 3 行：首行从路径变成 `wasted`（路径 + 空行 + efficiency 各占一行）
  frame.detail_scroll.scroll_by(3)
  draw(screen, frame)
  assert_true(screen.row_string(2)[42:].contains("wasted"))
  assert_false(screen.row_string(2)[42:].contains("/etc/hosts"))
}

///|
/// 建一个带 diff 的帧：`/etc/new` 新增、`/etc/hosts` 改写、`/etc` 没动过。
fn diff_fixture() -> (Screen, Frame) raise {
  let base = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
    @layer_tree.TarEntrySpec::File("etc/old", "x"),
  ])
  let top = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.2 longer"),
    @layer_tree.TarEntrySpec::File("etc/new", "y"),
    @layer_tree.TarEntrySpec::Whiteout("etc", "old"),
  ])
  let layers : Array[BytesView] = [base, top]
  let views = @layer_tree.browse_layers(layers) catch {
    err => fail(err.to_string())
  }
  let view = TreeView::from_tree_with_diff(
    views[1].tree,
    Some(views[1].diff),
    1,
    2,
    false,
  )
  let layout = Layout::compute(80, 24)
  let screen = Screen::new(layout.cols, layout.rows)
  (
    screen,
    {
      layout,
      view,
      image: "demo:latest",
      details: None,
      focus: Focus::Tree,
      detail_scroll: Viewport::new(0, 1),
      help_visible: false,
    },
  )
}

///|
/// 三类变化各上各的色；没动过的行暗一档（光标行除外，见下一个用例）。
test "draw colours rows by their diff status" {
  let (screen, frame) = diff_fixture()
  draw(screen, frame)
  let pane = frame.layout.pane(PaneId::Tree).unwrap()
  let style_of = fn(path) {
    let index = frame.view.index_of_path(path).unwrap()
    let row = pane.inner_top() + index - frame.view.offset
    screen.style_at(pane.inner_left(), row)
  }
  assert_eq(style_of("/etc/new"), style_added)
  assert_eq(style_of("/etc/hosts"), style_modified)
  // 没动过的 `/etc` 是暗一档；把光标挪开是为了不让它落在 `/etc` 上
  frame.view.move_to(frame.view.index_of_path("/etc/new").unwrap())
  draw(screen, frame)
  assert_eq(style_of("/etc"), style_dim)
}

///|
/// 光标行不换色：位置已经由 `>` 标出，再叠颜色会让两件事互相盖住。
test "draw leaves the cursor row in the default style" {
  let (screen, frame) = diff_fixture()
  frame.view.move_to(frame.view.index_of_path("/etc/new").unwrap())
  draw(screen, frame)
  let pane = frame.layout.pane(PaneId::Tree).unwrap()
  let row = pane.inner_top() + frame.view.cursor - frame.view.offset
  assert_eq(screen.style_at(pane.inner_left(), row), style_default)
  // 相邻的改写行仍然带色
  let hosts = frame.view.index_of_path("/etc/hosts").unwrap()
  assert_eq(
    screen.style_at(
      pane.inner_left(),
      pane.inner_top() + hosts - frame.view.offset,
    ),
    style_modified,
  )
}

///|
/// 状态行带图例：三组「符号 + 词」各自上色，颜色不自解释。
test "draw paints the diff legend in the status bar" {
  let (screen, frame) = diff_fixture()
  draw(screen, frame)
  let status = screen.row_string(frame.layout.status_row)
  assert_true(status.contains("+ add"))
  assert_true(status.contains("~ change"))
  // 每段只染自己的那几列，段间是默认样式，不是整行刷色
  let style_at = fn(col) { screen.style_at(col, frame.layout.status_row) }
  // 图例贴着右侧的位置计数排：`1/3` 占最后三列
  let legend_width = display_width("+ add") + 2 + display_width("~ change")
  // 位置计数是 `1/3 name`：图例贴在它左侧，中间空一格
  let position_width = display_width("1/3 name")
  let start = 80 - position_width - 1 - legend_width
  assert_eq(style_at(start), style_added)
  assert_eq(style_at(start + 4), style_added)
  assert_eq(style_at(start + 5), style_default)
  assert_eq(style_at(start + 7), style_modified)
  // 位置计数本身不上色（`1/3 size` 占右端，取末列即可）
  assert_eq(style_at(79), style_default)
}

///|
/// 窄屏放不下图例时整块不画：状态行被啃掉一半比没有图例更难看。
test "draw drops the whole legend when the status row is too narrow" {
  let (_, base) = render_fixture()
  // 15 列的图例 + 1 格间隔 + 位置计数，20 列里塞不下
  let layout = Layout::compute(18, 10)
  let narrow = Screen::new(layout.cols, layout.rows)
  draw(narrow, { ..base, layout, })
  let status = narrow.row_string(layout.status_row)
  assert_false(status.contains("add"))
  assert_false(status.contains("change"))
}
