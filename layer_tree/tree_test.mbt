///|
test "tree builds directories implicitly from file entries" {
  let archive = build_tar([File("usr/local/bin/tool", "x")])
  let tree = FileTree::new()
  apply_layer(tree, archive, 0)
  // 中间目录没有 entry，也要按需补齐
  assert_true(tree.get("/usr") is Some(_))
  assert_true(tree.get("/usr/local") is Some(_))
  assert_true(tree.get("/usr/local/bin") is Some(_))
  assert_true(tree.get("/usr/local/bin/tool") is Some(_))
  for path in ["/usr", "/usr/local", "/usr/local/bin"] {
    let node = match tree.get(path) {
      Some(node) => node
      None => fail("missing \{path}")
    }
    assert_eq(node.kind, NodeKind::Directory)
  }
}

///|
test "later layers overwrite earlier content in place" {
  let first = build_tar([File("app.bin", "short")])
  let second = build_tar([File("app.bin", "a much longer payload")])
  let tree = FileTree::new()
  apply_layer(tree, first, 0)
  apply_layer(tree, second, 1)
  assert_eq(size_at(tree, "/app.bin"), "a much longer payload".length())
  let node = match tree.get("/app.bin") {
    Some(node) => node
    None => fail("missing /app.bin")
  }
  assert_eq(node.layer, 1)
  // 覆盖历史保留两条记录
  let history = tree.history_of("/app.bin")
  assert_true(history.contains("L0"))
  assert_true(history.contains("L1"))
}

///|
test "symlinks record their target and are not followed" {
  let archive = build_tar([
    Dir("lib"),
    File("lib/libc.so.6", "binary"),
    Symlink("lib/libc.so", "libc.so.6"),
  ])
  let tree = FileTree::new()
  apply_layer(tree, archive, 0)
  let link = match tree.get("/lib/libc.so") {
    Some(node) => node
    None => fail("missing symlink")
  }
  assert_eq(link.kind, NodeKind::Symlink("libc.so.6"))
  assert_eq(link.link_target(), Some("libc.so.6"))
  assert_eq(link.size, 0)
  // 目标文件本身不受影响
  assert_eq(size_at(tree, "/lib/libc.so.6"), "binary".length())
}

///|
test "hardlinks point at their target instead of copying bytes" {
  let archive = build_tar([
    File("bin/tool", "payload"),
    Hardlink("bin/tool.alias", "tool"),
  ])
  let tree = FileTree::new()
  apply_layer(tree, archive, 0)
  let link = match tree.get("/bin/tool.alias") {
    Some(node) => node
    None => fail("missing hardlink")
  }
  assert_eq(link.kind, NodeKind::Hardlink("/bin/tool"))
  assert_eq(link.size, 0)
  assert_true(link.is_file())
  // 内容仍在原路径上
  assert_eq(size_at(tree, "/bin/tool"), "payload".length())
}

///|
test "relative hardlink targets resolve against the entry directory" {
  let archive = build_tar([
    Dir("a"),
    File("a/real", "data"),
    Hardlink("a/alias", "real"),
  ])
  let tree = FileTree::new()
  apply_layer(tree, archive, 0)
  let link = match tree.get("/a/alias") {
    Some(node) => node
    None => fail("missing hardlink")
  }
  assert_eq(link.kind, NodeKind::Hardlink("/a/real"))
}

///|
test "settings content over a directory replaces the node type" {
  let first = build_tar([Dir("var/log"), File("var/log/app.log", "log line")])
  let second = build_tar([File("var/log", "now a file")])
  let tree = FileTree::new()
  apply_layer(tree, first, 0)
  apply_layer(tree, second, 1)
  let node = match tree.get("/var/log") {
    Some(node) => node
    None => fail("missing /var/log")
  }
  assert_eq(node.kind, NodeKind::File)
  assert_eq(node.size, "now a file".length())
}

///|
test "paths escaping the root are dropped instead of failing the layer" {
  let builder = TarBuilder::new()
  builder.add_file("../escape.txt", "nope")
  builder.add_file("safe.txt", "yes")
  let tree = FileTree::new()
  apply_layer(tree, builder.finish(), 0)
  assert_true(tree.get("/safe.txt") is Some(_))
  assert_true(tree.get("/escape.txt") is None)
  // 也不能凭空造出树的上一级
  for path in tree.paths() {
    assert_false(path.contains(".."))
  }
}

///|
test "mode bits survive from tar headers" {
  let builder = TarBuilder::new()
  builder.add_file("script.sh", "#!/bin/sh\n", mode=0o755)
  builder.add_directory("private")
  let tree = FileTree::new()
  apply_layer(tree, builder.finish(), 0)
  let file = match tree.get("/script.sh") {
    Some(node) => node
    None => fail("missing script.sh")
  }
  assert_eq(file.mode, 0o755)
}

///|
test "tree paths are sorted and exclude the root" {
  let archive = build_tar([File("z", "1"), File("a", "1"), File("m/n", "1")])
  let tree = FileTree::new()
  apply_layer(tree, archive, 0)
  assert_eq(tree.paths(), ["/a", "/m", "/m/n", "/z"])
  assert_eq(tree.size(), 4)
}

///|
test "snapshot isolates earlier layers from later writes" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([File("f", "one")]), 0)
  let snapshot = tree.snapshot()
  apply_layer(tree, build_tar([File("f", "two-longer")]), 1)
  assert_eq(size_at(snapshot, "/f"), "one".length())
  assert_eq(size_at(tree, "/f"), "two-longer".length())
}
