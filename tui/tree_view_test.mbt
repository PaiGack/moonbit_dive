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

///|
/// 建一棵树 + 本层 diff，用于状态着色测试。
fn layered_view() -> TreeView raise {
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
  // 第 1 层的 diff：hosts 改写、new 新增、old 被 whiteout 删掉
  TreeView::from_tree_with_diff(views[1].tree, Some(views[1].diff), 1, 2, false)
}

///|
/// 每行的状态来自这一层的 diff：新增 / 改写 / 没动过。
test "tree view maps the layer diff onto row status" {
  let view = layered_view()
  let status = fn(path) {
    view.all_rows[view.index_of_path(path).unwrap()].status
  }
  assert_eq(status("/etc/new"), RowStatus::Added)
  assert_eq(status("/etc/hosts"), RowStatus::Modified)
  assert_eq(status("/etc"), RowStatus::Unchanged)
  // `old` 被 whiteout 删掉了，不在树上：没有行给它上色，状态里也不留 `Removed`
  assert_true(view.index_of_path("/etc/old") is None)
}

///|
/// 不给 diff 时一律 `Unchanged`（颜色不上），旧调用点行为不变。
test "tree view without a diff keeps every row unchanged" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  for row in view.all_rows {
    assert_eq(row.status, RowStatus::Unchanged)
  }
}

///|
/// 坐标反查与「行下标 → 屏幕行」互逆：画在第 `row` 行的项，
/// 反查 `row` 一定拿回它自己。
test "tree view maps screen rows back to indices" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.page_height = 4
  for row = 0; row < 4; row = row + 1 {
    let index = view.index_at_screen_row(row).unwrap()
    assert_eq(view.visible[index].path, view.visible[row].path)
  }
}

///|
/// 滚动后反查跟着 offset 走，不然点击会整体偏一行。
test "tree view reverse lookup follows the scroll offset" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.page_height = 3
  view.move_to_end()
  view.clamp_offset()
  assert_eq(view.offset, 3)
  assert_eq(view.index_at_screen_row(0), Some(3))
  assert_eq(view.index_at_screen_row(2), Some(5))
}

///|
/// 点在面板空白格（可视行之外）给 `None`，不夹到首行/末行。
test "tree view reverse lookup gives none for empty rows" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.page_height = 20
  // 只有 6 行内容，第 6 行（0 起）以下是空的
  assert_eq(view.index_at_screen_row(6), None)
  assert_eq(view.index_at_screen_row(-1), None)
  // 画帧前 `page_height` 是 0：整块都算不可命中
  let fresh = TreeView::from_tree(tree, 0, 3)
  assert_eq(fresh.index_at_screen_row(0), None)
}

///|
/// 点中就落光标；点空白不动它（也不假装动了）。
test "tree view selects a row under the screen coordinate" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 3)
  view.page_height = 4
  assert_true(view.select_at_screen_row(2))
  assert_eq(view.cursor, 2)
  assert_false(view.select_at_screen_row(19))
  assert_eq(view.cursor, 2)
}

///|
/// 按大小排序：目录在前，文件按体积降序，同体积按路径。
test "tree view sorts rows by size on demand" {
  let tree = @layer_tree.FileTree::new()
  let tar = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("small"),
    @layer_tree.TarEntrySpec::File("small/tiny", "a"),
    @layer_tree.TarEntrySpec::File("big", "aaaaaaaaaa"),
    @layer_tree.TarEntrySpec::File("mid", "aaaaa"),
  ])
  @layer_tree.apply_layer(tree, tar, 0) catch {
    err => fail(err.to_string())
  }
  let by_name = TreeView::from_tree(tree, 0, 1)
  assert_eq(by_name.visible[0].path, "/big")
  let by_size = TreeView::from_tree_with_diff(tree, None, 0, 1, true)
  assert_true(by_size.sort_by_size)
  // 目录 `small` 排最前，后面是文件按体积降序
  assert_eq(by_size.visible[0].path, "/small")
  assert_eq(by_size.visible[1].path, "/big")
  assert_eq(by_size.visible[2].path, "/mid")
  assert_eq(by_size.visible[3].path, "/small/tiny")
}

///|
/// 行带上了权限与 mtime：`Ctrl+B` 的属性要读它们，之前 `Row` 没带出来。
test "tree view carries mode and mtime onto rows" {
  let tree = @layer_tree.FileTree::new()
  let tar = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1"),
  ])
  @layer_tree.apply_layer(tree, tar, 0) catch {
    err => fail(err.to_string())
  }
  let view = TreeView::from_tree(tree, 0, 1)
  let dir = find_row(view, "/etc")
  let file = find_row(view, "/etc/hosts")
  // 目录 0o755，文件 0o644（fixture 的默认值）
  assert_eq(dir.mode, 0o755)
  assert_eq(file.mode, 0o644)
  // mtime 由 fixture 写在 header 里，缺省是 0（这里只要求字段被带出来，不做时间换算）
  assert_eq(file.mtime, 0)
}

///|
/// 过滤：只看某一档时可见行被裁到只剩那一档，撤销后原样回来。
test "tree view filters rows by diff group" {
  let view = layered_view()
  let total = view.visible.length()
  assert_eq(view.only_group(), None)
  assert_true(view.has_in_group(RowGroup::AddedOnly))
  assert_true(view.has_in_group(RowGroup::ModifiedOnly))
  // 过滤与折叠互不干扰：过滤只看 status，不看 collapsed
  view.set_filter(Some(RowGroup::ModifiedOnly))
  assert_eq(view.only_group(), Some(RowGroup::ModifiedOnly))
  assert_eq(view.visible.length(), 1)
  assert_eq(view.visible[0].path, "/etc/hosts")
  view.set_filter(None)
  assert_eq(view.only_group(), None)
  assert_eq(view.visible.length(), total)
}

///|
/// 同一档连按两次 = 撤销（与 dive 的「反转过滤」同效），不会卡在过滤态里。
test "setting the same filter twice clears it" {
  let view = layered_view()
  view.set_filter(Some(RowGroup::AddedOnly))
  assert_eq(view.only_group(), Some(RowGroup::AddedOnly))
  view.set_filter(Some(RowGroup::AddedOnly))
  assert_eq(view.only_group(), None)
}

///|
/// 全折叠 / 全展开：按一次全折、再按一次全展，且光标不跳到顶。
///
/// 「现在算不算全折」看的是**效果**不是 `collapsed` 的大小：
/// 光标落在被折掉的子行上时，全折一次之后只剩祖先行可见，
/// 若拿 `collapsed` 的大小去比，第二次就会误判成「已经全折好了」而不再展开。
test "collapse all folds every directory and expands back" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 1)
  view.move_to(view.index_of_path("/usr/bin/sh").unwrap())
  assert_eq(view.cursor, view.visible.length() - 1)
  view.toggle_collapse_all()
  // `/etc` 与 `/usr` 都折上，子树的行不再可见
  assert_true(view.collapsed.contains("/etc"))
  assert_true(view.collapsed.contains("/usr"))
  assert_eq(view.visible.length(), 2)
  // 光标落在被折掉的子行上时，落到最近的可见祖先
  assert_eq(view.visible[view.cursor].path, "/usr")
  view.toggle_collapse_all()
  assert_true(view.collapsed.is_empty())
  assert_eq(view.visible.length(), tree.size())
}

///|
/// 全折叠幂等：连按两次回到全展，中间不因为可见行变化而误判。
test "collapse all is idempotent across two presses" {
  let tree = sample_tree()
  let view = TreeView::from_tree(tree, 0, 1)
  view.toggle_collapse_all()
  let folded = view.visible.length()
  view.toggle_collapse_all()
  view.toggle_collapse_all()
  assert_eq(view.visible.length(), folded)
}
