///|
/// 逐层浏览：每层的树形状独立，互不影响。
test "browse_layers snapshots each layer independently" {
  let layer0 = build_tar([
    Dir("etc"),
    File("etc/hosts", "127.0.0.1 localhost"),
    File("etc/passwd", "root:x:0:0"),
  ])
  let layer1 = build_tar([
    Whiteout("etc", "passwd"),
    File("etc/hosts", "127.0.0.1 localhost\n::1 localhost"),
  ])
  let views = browse_layers([layer0, layer1]) catch {
    err => fail(err.to_string())
  }
  assert_eq(views.length(), 2)
  // 第 0 层：passwd 还在
  assert_true(views[0].tree.get("/etc/passwd") is Some(_))
  assert_eq(views[0].tree.size(), 3)
  assert_eq(views[0].diff.base, -1)
  assert_eq(views[0].diff.added.length(), 3)
  // 第 1 层：passwd 已消失，hosts 被改写
  assert_true(views[1].tree.get("/etc/passwd") is None)
  assert_eq(views[1].diff.removed, ["/etc/passwd"])
  assert_eq(views[1].diff.modified, ["/etc/hosts"])
}

///|
/// 视图里的层号要跟层对齐。
test "browse_layers numbers layers in order" {
  let views = browse_layers([
    build_tar([File("a.txt", "1")]),
    build_tar([File("b.txt", "2")]),
    build_tar([File("c.txt", "3")]),
  ]) catch {
    err => fail(err.to_string())
  }
  assert_eq(views.length(), 3)
  for index, view in views {
    assert_eq(view.layer, index)
    assert_eq(view.tree.size(), index + 1)
  }
}

///|
/// `changed_paths` 合并 diff 三组并去重排序。
test "changed_paths merges diff groups" {
  let views = browse_layers([
    build_tar([File("keep", "x"), File("gone", "y")]),
    build_tar([Whiteout("", "gone"), File("keep", "xz"), File("new", "n")]),
  ]) catch {
    err => fail(err.to_string())
  }
  assert_eq(views[1].changed_paths(), ["/gone", "/keep", "/new"])
}

///|
/// 子视图只保留前缀自身与子树，其余不带。
test "subtree keeps only the requested prefix" {
  let views = browse_layers([
    build_tar([
      Dir("app"),
      File("app/main.js", "m"),
      Dir("lib"),
      File("lib/util.js", "u"),
    ]),
  ]) catch {
    err => fail(err.to_string())
  }
  let view = views[0]
  let app = view.subtree("/app")
  assert_eq(app.size(), 2)
  assert_true(app.get("/app") is Some(_))
  assert_true(app.get("/app/main.js") is Some(_))
  assert_true(app.get("/lib") is None)
  // 前缀归一化：不带前导斜杠也能用
  assert_eq(view.subtree("lib").size(), 2)
  // 通配符不是路径，按字面处理 -> 找不到，只剩空树
  assert_eq(view.subtree("lib/*").size(), 0)
  // 精确到文件时，沿途祖先目录作为缩进参照保留
  let file = view.subtree("/app/main.js")
  assert_eq(file.size(), 2)
  assert_true(file.get("/app") is Some(_))
  assert_true(file.get("/app/main.js") is Some(_))
  // 不存在的路径得到空树
  assert_eq(view.subtree("/nope").size(), 0)
}

///|
/// 子视图里的节点不能被后续层污染（拷贝而非引用）。
test "subtree nodes are copied" {
  let views = browse_layers([build_tar([File("a.txt", "hello")])]) catch {
    err => fail(err.to_string())
  }
  let subtree = views[0].subtree("/a.txt")
  let node = match subtree.get("/a.txt") {
    Some(node) => node
    None => fail("expected /a.txt")
  }
  node.size = 999
  let original = match views[0].tree.get("/a.txt") {
    Some(node) => node
    None => fail("expected /a.txt in view")
  }
  assert_eq(original.size, 5)
}

///|
/// LayerView 的 Show 能一眼看出是哪一层。
test "layer view to_string mentions the layer" {
  let views = browse_layers([build_tar([File("a", "1")])]) catch {
    err => fail(err.to_string())
  }
  assert_true(views[0].to_string().contains("L0"))
}
