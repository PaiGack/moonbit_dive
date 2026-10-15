///|
/// 在视图里按路径找行。
fn find_row(view : TreeView, path : String) -> Row {
  for row in view.all_rows {
    if row.path == path {
      return row
    }
  }
  abort("row not found: \{path}")
}

///|
/// 建一棵供测试用的树：/etc/{hosts,passwd} + /usr/bin/sh。
fn sample_tree() -> @layer_tree.FileTree raise {
  let tree = @layer_tree.FileTree::new()
  let tar = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
    @layer_tree.TarEntrySpec::File("etc/passwd", "root:x"),
    @layer_tree.TarEntrySpec::Dir("usr"),
    @layer_tree.TarEntrySpec::Dir("usr/bin"),
    @layer_tree.TarEntrySpec::File("usr/bin/sh", "#!/bin/sh"),
  ])
  @layer_tree.apply_layer(tree, tar, 0) catch {
    err => fail(err.to_string())
  }
  tree
}

///|
/// 拍平后的行数 = 树内路径数（根 `/` 不算行）。
test "tree view flattens every non-root path into a row" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  assert_eq(tree.size(), 6)
  assert_eq(view.all_rows.length(), 6)
  assert_eq(view.visible.length(), 6)
  assert_eq(view.cursor, 0)
}

///|
/// 行的深度按路径段数算：`/etc/hosts` 是 2，`/usr/bin/sh` 是 3。
test "tree view computes row depth from path segments" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  let hosts = find_row(view, "/etc/hosts")
  let sh = find_row(view, "/usr/bin/sh")
  assert_eq(hosts.depth, 2)
  assert_eq(sh.depth, 3)
  assert_true(hosts.is_dir == false)
}

///|
/// 光标上下移动夹在边界内。
test "tree view moves the cursor within bounds" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.move_up()
  assert_eq(view.cursor, 0)
  view.move_down()
  assert_eq(view.cursor, 1)
  view.move_to_end()
  assert_eq(view.cursor, view.visible.length() - 1)
  view.move_down()
  assert_eq(view.cursor, view.visible.length() - 1)
  view.move_to_home()
  assert_eq(view.cursor, 0)
}

///|
/// 收起 `/etc`：它的后代从可见行里消失，自己还留着。
test "tree view hides descendants of a collapsed directory" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  let etc = view.index_of_path("/etc").unwrap()
  view.move_to(etc)
  view.toggle()
  assert_true(view.collapsed.contains("/etc"))
  assert_true(view.index_of_path("/etc/hosts") is None)
  assert_true(view.index_of_path("/etc") is Some(_))
  // 其它子树不受影响
  assert_true(view.index_of_path("/usr/bin/sh") is Some(_))
}

///|
/// 再次 toggle 展开复原。
test "tree view toggles a directory back open" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.move_to(view.index_of_path("/etc").unwrap())
  view.toggle()
  view.toggle()
  assert_false(view.collapsed.contains("/etc"))
  assert_true(view.index_of_path("/etc/hosts") is Some(_))
}

///|
/// 非目录行 toggle 不动——折叠只对目录有意义。
test "tree view ignores toggle on a file row" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.move_to(view.index_of_path("/etc/hosts").unwrap())
  view.toggle()
  assert_eq(view.collapsed.length(), 0)
}

///|
/// 光标在被折叠的子树里时，落点不能丢（跳到最近的可见行）。
test "tree view keeps the cursor valid when its subtree collapses" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.move_to(view.index_of_path("/etc/hosts").unwrap())
  view.collapse()
  assert_true(view.cursor >= 0 && view.cursor < view.visible.length())
  assert_eq(view.visible[view.cursor].path, "/etc")
}

///|
/// `→` 对已展开目录下钻到第一个子行，对收起目录就地展开。
test "tree view expand descends or opens" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.move_to(view.index_of_path("/usr").unwrap())
  view.expand()
  // 已展开的目录：光标下移到第一个子行
  assert_eq(view.visible[view.cursor].path, "/usr/bin")
  // 收起后再 expand：就地打开，光标不动
  view.collapse()
  assert_true(view.collapsed.contains("/usr/bin"))
  let before = view.cursor
  view.expand()
  assert_false(view.collapsed.contains("/usr/bin"))
  assert_eq(view.cursor, before)
}

///|
/// `←` 在已收起 / 是文件时回到父目录。
test "tree view collapse walks up to the parent" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.move_to(view.index_of_path("/usr/bin/sh").unwrap())
  view.collapse()
  assert_eq(view.visible[view.cursor].path, "/usr/bin")
}

///|
/// 滚动的夹取：光标走到底时 offset 跟上，且不超过上限。
test "tree view clamps the scroll offset" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.page_height = 3
  view.move_to_end()
  view.clamp_offset()
  assert_eq(view.cursor, 5)
  assert_eq(view.offset, 3)
  view.move_to_home()
  view.clamp_offset()
  assert_eq(view.offset, 0)
}

///|
/// 翻页按步长前进，越界夹住。
test "tree view pages by step" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.page_height = 2
  view.page_down(2)
  assert_eq(view.cursor, 2)
  view.page_up(1)
  assert_eq(view.cursor, 1)
  view.page_up(100)
  assert_eq(view.cursor, 0)
}

///|
/// 空视图不 panic：没有行时游标夹到 0。
test "tree view handles an empty tree" {
  let tree = @layer_tree.FileTree::new()
  let view = TreeView::from_tree(tree, 0, 1)
  assert_eq(view.visible.length(), 0)
  view.move_down()
  view.toggle()
  view.collapse()
  view.expand()
  assert_eq(view.cursor, 0)
}
