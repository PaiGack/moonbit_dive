///|
test "node accessors describe every kind" {
  let file = Node::new("/a.txt", NodeKind::File, size=3)
  assert_true(file.is_file())
  assert_false(file.is_dir())
  assert_false(file.is_link())
  assert_eq(file.link_target(), None)
  let dir = Node::new("/d", NodeKind::Directory)
  assert_true(dir.is_dir())
  assert_false(dir.is_file())
  let symlink = Node::new("/s", NodeKind::Symlink("a.txt"))
  assert_true(symlink.is_link())
  assert_false(symlink.is_file())
  assert_eq(symlink.link_target(), Some("a.txt"))
  let hardlink = Node::new("/h", NodeKind::Hardlink("/a.txt"))
  assert_true(hardlink.is_file())
  assert_true(hardlink.is_link())
  assert_eq(hardlink.link_target(), Some("/a.txt"))
}

///|
test "node kinds render readably" {
  assert_eq(NodeKind::File.to_string(), "file")
  assert_eq(NodeKind::Directory.to_string(), "dir")
  assert_eq(NodeKind::Symlink("x").to_string(), "symlink")
  assert_eq(NodeKind::Hardlink("/y").to_string(), "hardlink")
}

///|
test "node show strings mention the interesting part" {
  assert_eq(Node::new("/a", NodeKind::File, size=2).to_string(), "/a (2 bytes)")
  assert_eq(Node::new("/d", NodeKind::Directory).to_string(), "/d/")
  assert_eq(Node::new("/s", NodeKind::Symlink("t")).to_string(), "/s -> t")
  assert_eq(Node::new("/h", NodeKind::Hardlink("/t")).to_string(), "/h ==> /t")
}

///|
test "children can be found and removed by path" {
  let parent = Node::new("/d", NodeKind::Directory)
  parent.insert_child(Node::new("/d/a", NodeKind::File))
  parent.insert_child(Node::new("/d/b", NodeKind::File))
  assert_true(parent.find_child("/d/a") is Some(_))
  assert_true(parent.find_child("/d/zz") is None)
  assert_true(parent.remove_child("/d/a"))
  assert_true(parent.find_child("/d/a") is None)
  assert_false(parent.remove_child("/d/a"))
}

///|
test "empty path helpers keep root semantics" {
  assert_eq(parent_path(""), "/")
  assert_eq(base_name(""), "")
  assert_eq(join_path("/", ""), "/")
  assert_eq(join_path("", "a/b"), "/a/b")
  assert_eq(normalize_path_lossy_probe(), "/")
}

///|
/// `join_path`/`parent_path` 的兜底分支：极端输入不 panic。
fn normalize_path_lossy_probe() -> String {
  join_path("/a", "..").parent_probe()
}

///|
/// 用扩展方法调用一次 `parent_path`，顺带覆盖空输入分支。
fn String::parent_probe(self : String) -> String {
  parent_path(self)
}

///|
test "path_order orders prefixes before their children" {
  assert_eq(path_order("/a", "/a/b"), -1)
  assert_eq(path_order("/a/b", "/a"), 1)
  assert_eq(path_order("/a", "/a"), 0)
  assert_eq(path_order("/b", "/a/c"), 1)
}

///|
test "path_depth and path_is_under agree with the root" {
  assert_true(path_is_under("/", "/"))
  assert_eq(path_depth(""), 0)
  assert_eq(compare_ascii("abc", "abc"), 0)
  assert_eq(compare_ascii("abc", "abd"), -1)
  assert_eq(compare_ascii("abd", "abc"), 1)
  assert_eq(compare_ascii("ab", "abc"), -1)
  assert_eq(compare_ascii("abc", "ab"), 1)
}

///|
test "tree exposes root, size and layer stats" {
  let tree = FileTree::new()
  assert_eq(tree.root().path, "/")
  assert_eq(tree.size(), 0)
  assert_eq(tree.layers, 0)
  apply_layer(tree, build_tar([File("a", "1")]), 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  assert_eq(tree.size(), 1)
  assert_eq(tree.layers, 1)
  let stat = match tree.stat(0) {
    Some(stat) => stat
    None => fail("missing stats for layer 0")
  }
  assert_eq(stat.changed_paths, 1)
  assert_true(tree.stat(9) is None)
}

///|
test "tree require fails loudly for a missing path" {
  let tree = FileTree::new()
  let result = try {
    ignore(tree.require("/nope"))
    None
  } catch {
    err => Some(err)
  }
  assert_true(result is Some(_))
  assert_eq(tree.require("/").path, "/")
}

///|
test "tree history lists every writer of a path" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([File("f", "1")]), 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  apply_layer(tree, build_tar([File("f", "22")]), 1) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  let history = tree.history_of("/f")
  assert_true(history.contains("L0"))
  assert_true(history.contains("L1"))
  // 从未写过的路径没有历史
  assert_eq(tree.history_of("/never"), "")
}

///|
test "tree and stat render readably" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([File("a", "1")]), 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  assert_eq(tree.to_string(), "FileTree(layers=1, nodes=1)")
  let stat = tree.stat(0).unwrap()
  assert_true(stat.to_string().contains("L0"))
}

///|
test "diff renders readably and against an empty tree" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([File("a", "1")]), 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  let diff = diff_against_empty(tree, 0)
  assert_eq(diff.base, -1)
  assert_eq(diff.added, ["/a"])
  assert_true(diff.to_string().contains("L0"))
  assert_eq(diff.total(), 2) // added 与 modified 各一条
}

///|
test "diff_snapshots keeps working when only sizes change" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([File("a", "1")]), 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  let before = tree.snapshot()
  apply_layer(tree, build_tar([File("a", "12345")]), 1) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  let diff = diff_snapshots(before, tree.snapshot(), 0, 1)
  assert_eq(diff.modified, ["/a"])
  assert_true(diff.added.is_empty())
  assert_true(diff.removed.is_empty())
}

///|
test "error types render human readable messages" {
  assert_eq(
    TarError::Truncated("boom").to_string(),
    "truncated tar stream: boom",
  )
  assert_true(
    TarError::InvalidNumber("size", "zz").to_string().contains("size"),
  )
  assert_eq(
    DecompressError::Gzip("bad").to_string(),
    "invalid gzip stream: bad",
  )
  assert_eq(
    DecompressError::Zstd("bad").to_string(),
    "invalid zstd stream: bad",
  )
  assert_eq(
    DecompressError::Unsupported("lz4").to_string(),
    "unsupported layer compression: lz4",
  )
  assert_true(
    LayerError::DigestMismatch("sha256:a", "sha256:b")
    .to_string()
    .contains("mismatch"),
  )
  assert_true(LayerError::PathEscape("../x").to_string().contains("escapes"))
  assert_eq(
    PathError::Escape("../x").to_string(),
    "path \"../x\" escapes the tree root",
  )
}
