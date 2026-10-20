///|
/// OCI gzip layer 的 media type，测试里用来驱动压缩分支。
let oci_gzip_media_type : String = "application/vnd.oci.image.layer.v1.tar+gzip"

///|
/// 把若干层 tar 依次应用到一棵树上。
fn apply_all(layers : Array[Bytes]) -> FileTree raise {
  let tree = FileTree::new()
  for index, layer in layers {
    apply_layer(tree, layer, index)
  }
  tree
}

///|
/// 某路径当前的大小。
fn size_at(tree : FileTree, path : String) -> Int32 {
  match tree.get(path) {
    Some(node) => node.size
    None => -1
  }
}

///|
async test "whiteout entry removes a sibling file" {
  let first = build_tar([Dir("etc"), File("etc/passwd", "root:x:0:0")])
  let second = build_tar([Whiteout("etc", "passwd")])
  let tree = apply_all([first, second])
  assert_true(tree.get("/etc/passwd") is None)
  // 目录本身还在
  assert_true(tree.get("/etc") is Some(_))
  // whiteout 条目自身不能出现在树上
  assert_true(tree.get("/etc/.wh.passwd") is None)
}

///|
async test "whiteout only affects its own directory" {
  let first = build_tar([
    Dir("a"),
    Dir("b"),
    File("a/dup.txt", "in a"),
    File("b/dup.txt", "in b"),
  ])
  let second = build_tar([Whiteout("a", "dup.txt")])
  let tree = apply_all([first, second])
  assert_true(tree.get("/a/dup.txt") is None)
  assert_true(tree.get("/b/dup.txt") is Some(_))
}

///|
async test "whiteout on a directory removes the whole subtree" {
  let first = build_tar([
    Dir("opt"),
    Dir("opt/tools"),
    File("opt/tools/one", "1"),
    File("opt/tools/two", "2"),
    File("opt/keep", "k"),
  ])
  let second = build_tar([Whiteout("opt", "tools")])
  let tree = apply_all([first, second])
  assert_true(tree.get("/opt/tools") is None)
  assert_true(tree.get("/opt/tools/one") is None)
  assert_true(tree.get("/opt/tools/two") is None)
  assert_true(tree.get("/opt/keep") is Some(_))
}

///|
async test "a file re-created after a whiteout is a fresh node" {
  // 这是 OCI 里最常见的边界：同一层里先 whiteout 再写回同名文件
  let first = build_tar([Dir("app"), File("app/config", "old")])
  let second = build_tar([
    Whiteout("app", "config"),
    File("app/config", "new-and-longer"),
  ])
  let tree = apply_all([first, second])
  assert_eq(size_at(tree, "/app/config"), "new-and-longer".length())
  assert_true(tree.get("/app/config") is Some(_))
}

///|
async test "whiteout then re-create in the same layer shows up as modified" {
  let first = build_tar([Dir("app"), File("app/config", "old")])
  let second = build_tar([
    Whiteout("app", "config"),
    File("app/config", "brand new content"),
  ])
  let tree = FileTree::new()
  apply_layer(tree, first, 0)
  let before = tree.snapshot()
  apply_layer(tree, second, 1)
  let diff = diff_snapshots(before, tree.snapshot(), 0, 1)
  // 路径在两层里都存在，但内容换了：算 modified，而不是 removed + added
  assert_true(diff.modified.contains("/app/config"))
  assert_false(diff.removed.contains("/app/config"))
  assert_eq(size_at(tree, "/app/config"), "brand new content".length())
}

///|
async test "whiteout without re-create shows up as removed in diff" {
  let first = build_tar([Dir("app"), File("app/config", "old")])
  let second = build_tar([Whiteout("app", "config")])
  let tree = FileTree::new()
  apply_layer(tree, first, 0)
  let before = tree.snapshot()
  apply_layer(tree, second, 1)
  let diff = diff_snapshots(before, tree.snapshot(), 0, 1)
  assert_true(diff.removed.contains("/app/config"))
  assert_true(diff.added.is_empty())
  assert_true(diff.modified.is_empty())
}

///|
async test "opaque directory drops entries the new layer did not write" {
  let first = build_tar([
    Dir("srv"),
    File("srv/legacy.conf", "old"),
    File("srv/keep.conf", "keep"),
  ])
  // 第二层把 /srv 变成 opaque，只写回 keep.conf
  let second = build_tar([Opaque("srv"), File("srv/keep.conf", "keep")])
  let tree = apply_all([first, second])
  assert_true(tree.get("/srv/legacy.conf") is None)
  assert_true(tree.get("/srv/keep.conf") is Some(_))
  assert_true(tree.get("/srv/.wh..wh..opq") is None)
}

///|
async test "opaque directory keeps files written by the same layer" {
  let first = build_tar([Dir("data"), File("data/old.txt", "old")])
  let second = build_tar([
    Opaque("data"),
    File("data/fresh.txt", "fresh"),
    File("data/more.txt", "more"),
  ])
  let tree = apply_all([first, second])
  assert_true(tree.get("/data/old.txt") is None)
  assert_true(tree.get("/data/fresh.txt") is Some(_))
  assert_true(tree.get("/data/more.txt") is Some(_))
}

///|
async test "plnk marker is recognised but never lands in the tree" {
  let builder = TarBuilder::new()
  builder.add_directory("var")
  builder.add_header("var/.wh..wh..plnk", 0, entry_type=b'0')
  let tree = apply_all([builder.finish()])
  assert_true(tree.get("/var/.wh..wh..plnk") is None)
}

///|
async test "whiteout_kind classifies all three marker forms" {
  assert_eq(
    whiteout_kind("etc/.wh.passwd"),
    Some(WhiteoutKind::Entry("passwd")),
  )
  assert_eq(whiteout_kind(".wh.foo"), Some(WhiteoutKind::Entry("foo")))
  assert_eq(whiteout_kind("var/.wh..wh..opq"), Some(WhiteoutKind::Opaque))
  assert_eq(whiteout_kind("var/.wh..wh..plnk"), Some(WhiteoutKind::Plnk))
  assert_eq(whiteout_kind("etc/passwd"), None)
  // `.wh.` 出现在中间段时是普通目录名，不是 whiteout
  assert_eq(whiteout_kind("etc/.wh.nested/file"), None)
}

///|
async test "whiteout in a compressed layer behaves the same" {
  let first = build_tar([Dir("etc"), File("etc/hosts", "127.0.0.1")])
  let second = build_tar([Whiteout("etc", "hosts")])
  let tree = FileTree::new()
  apply_layer(tree, first, 0)
  apply_layer_with_media_type(
    tree,
    gzip_compress(second),
    oci_gzip_media_type,
    1,
  ) catch {
    err => fail("gzip layer should apply: \{err.to_string()}")
  }
  assert_true(tree.get("/etc/hosts") is None)
}

///|
async test "a bare .wh. prefix is not a whiteout" {
  // `.wh.` 后面没有名字时语义不完整，不作为删除处理
  assert_eq(whiteout_kind("etc/.wh."), None)
  assert_eq(whiteout_kind(".wh."), None)
}

///|
async test "whiteout kinds render readably" {
  assert_eq(WhiteoutKind::Entry("passwd").to_string(), "whiteout entry passwd")
  assert_eq(WhiteoutKind::Opaque.to_string(), "opaque directory")
  assert_eq(WhiteoutKind::Plnk.to_string(), "plnk marker (ignored)")
}

///|
async test "whiteout markers never become tree nodes" {
  // 三种标记混在一层里：最终树上都不该出现
  let builder = TarBuilder::new()
  builder.add_directory("etc")
  builder.add_file("etc/keep", "k")
  builder.add_whiteout("etc", "gone")
  builder.add_opaque("etc")
  builder.add_header("etc/.wh..wh..plnk", 0, entry_type=b'0')
  let tree = apply_all([builder.finish()])
  for path in tree.paths() {
    assert_false(path.contains(".wh."))
  }
  assert_true(tree.get("/etc/keep") is Some(_))
}

///|
async test "whiteout removes an entry that lives in an earlier layer only" {
  // 目标只在更早的层出现过，whiteout 仍然要生效
  let layers = [
    build_tar([Dir("opt"), File("opt/tool", "binary")]),
    build_tar([File("opt/other", "x")]),
    build_tar([Whiteout("opt", "tool")]),
  ]
  let tree = apply_all(layers)
  assert_true(tree.get("/opt/tool") is None)
  assert_true(tree.get("/opt/other") is Some(_))
}

///|
async test "whiting out a missing path is a no-op" {
  let first = build_tar([Dir("etc"), File("etc/a", "1")])
  let second = build_tar([Whiteout("etc", "never-existed")])
  let tree = apply_all([first, second])
  assert_eq(tree.paths(), ["/etc", "/etc/a"])
}

///|
async test "opaque on the root keeps only the current layer" {
  let first = build_tar([Dir("a"), Dir("b"), File("a/x", "1"), File("b/y", "2")])
  let second = build_tar([Opaque("/"), File("c", "3")])
  let tree = apply_all([first, second])
  assert_true(tree.get("/a") is None)
  assert_true(tree.get("/b") is None)
  assert_true(tree.get("/c") is Some(_))
}
