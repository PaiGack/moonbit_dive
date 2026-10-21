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
    assert_eq(node.info.kind, NodeKind::Directory)
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
  assert_eq(node.info.layer, 1)
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
  assert_eq(link.info.kind, NodeKind::Symlink("libc.so.6"))
  assert_eq(link.link_target(), Some("libc.so.6"))
  assert_eq(link.info.size, 0)
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
  assert_eq(link.info.kind, NodeKind::Hardlink("/bin/tool"))
  assert_eq(link.info.size, 0)
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
  assert_eq(link.info.kind, NodeKind::Hardlink("/a/real"))
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
  assert_eq(node.info.kind, NodeKind::File)
  assert_eq(node.info.size, "now a file".length())
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
  assert_eq(file.info.mode, 0o755)
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

///|
/// 快照共享没动过的节点：一份快照不是「又一次全量重建」。
///
/// 这条钉的是 issue #122 第 5 项的前提——节点不可变之后，快照可以按路径
/// 指着同一份节点。改成可变节点的话这里会立刻红。
test "snapshot shares nodes that later layers never touch" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([Dir("keep"), File("keep/a", "a")]), 0)
  let snapshot = tree.snapshot()
  apply_layer(tree, build_tar([Dir("other"), File("other/b", "b")]), 1)
  let before = match snapshot.get("/keep/a") {
    Some(node) => node
    None => fail("missing /keep/a in snapshot")
  }
  let after = match tree.get("/keep/a") {
    Some(node) => node
    None => fail("missing /keep/a in tree")
  }
  // 同一个节点：没被碰过的路径不复制（节点不可变，共享是安全的）
  assert_true(before.info == after.info)
  assert_eq(before.files.length(), after.files.length())
  // 快照的根不能跟着后面几层长大
  assert_eq(snapshot.root().children.length(), 1)
  assert_eq(tree.root().children.length(), 2)
}

///|
/// 「先快照、再叠层」不能把快照里的节点改掉：覆写、删除、opaque 三条路都要过。
test "snapshot survives overwrite delete and opaque" {
  let tree = FileTree::new()
  apply_layer(
    tree,
    build_tar([
      Dir("etc"),
      File("etc/hosts", "old"),
      File("etc/passwd", "root"),
      Dir("var"),
      File("var/log", "log"),
    ]),
    0,
  )
  let snapshot = tree.snapshot()
  apply_layer(
    tree,
    build_tar([
      File("etc/hosts", "new and longer"),
      Whiteout("etc", "passwd"),
      Opaque("var"),
    ]),
    1,
  )
  // 快照还是第 0 层的形状
  assert_eq(size_at(snapshot, "/etc/hosts"), "old".length())
  assert_true(snapshot.get("/etc/passwd") is Some(_))
  assert_true(snapshot.get("/var/log") is Some(_))
  assert_eq(snapshot.size(), 5)
  // 树上已经是第 1 层
  assert_eq(size_at(tree, "/etc/hosts"), "new and longer".length())
  assert_true(tree.get("/etc/passwd") is None)
  assert_true(tree.get("/var/log") is None)
}

///|
/// 快照里 `root().children` 也要是那一刻的形状——根 likewise 不可变。
test "snapshot root children stay at the snapshot time" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([File("a", "1")]), 0)
  let snapshot = tree.snapshot()
  apply_layer(tree, build_tar([File("b", "2")]), 1)
  let children = snapshot.root().children.map(fn(child) { child.path })
  assert_eq(children, ["/a"])
  assert_eq(tree.root().children.length(), 2)
}

///|
/// 节点不可变：换一份元数据得到新节点，`children` 与旧的一起用。
test "overwrite returns a new node and leaves the old one alone" {
  let dir = Node::new("/d", NodeKind::Directory, layer=0)
  let child = Node::new("/d/a", NodeKind::File, size=1)
  let dir = dir.insert_child(child)
  let overwritten = child.overwrite(NodeKind::File, size=99, layer=1)
  assert_eq(child.info.size, 1)
  assert_eq(overwritten.info.size, 99)
  assert_eq(overwritten.info.layer, 1)
  // 父目录没被改到
  assert_eq(dir.children.length(), 1)
}
