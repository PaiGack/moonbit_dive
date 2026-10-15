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
  (screen, { layout, view, image: "demo:latest", details: None, })
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
  assert_true(status.contains("q"))
  assert_true(status.contains("1/3"))
}

///|
/// 树行带缩进、名称与层号；光标行以 `>` 起头。
test "draw paints tree rows with cursor and layer" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  let body = screen.row_string(1)
  assert_true(body.has_prefix(">"))
  // 行显示的是 basename（路径层级靠缩进表达）
  assert_true(body.contains("etc"))
  assert_true(body.contains("[L0]"))
}

///|
/// 目录行前带折叠标记：展开是 `-`。
test "draw marks expanded directories" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  let body = screen.row_string(1)
  assert_true(body.contains("- etc"))
}

///|
/// 没有详情数据源时右栏留空，不画半截面板。
test "draw leaves the detail pane blank without a source" {
  let (screen, frame) = render_fixture()
  draw(screen, frame)
  // 右栏第一列（41）是空的
  assert_eq(screen.get(41, 1), ' ')
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
  draw(screen, { layout, view, image: "demo", details: None, })
  // `main` 与 `1 B` 之间是补齐的空格，不是直接相连
  let body = screen.row_string(2)
  assert_true(body.contains("main"))
  assert_true(body.contains("1 B [L0]"))
  assert_false(body.contains("main1 B"))
}
