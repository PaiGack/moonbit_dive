///|
/// README 里的示例：多层 tar 的 whiteout 与 diff。
async test "README example" {
  // 手工造两层 tar（真实场景下数据来自镜像 registry）
  let layer0 = build_tar([
    Dir("etc"),
    File("etc/hosts", "127.0.0.1 localhost"),
    File("etc/passwd", "root:x:0:0"),
  ])
  let layer1 = build_tar([
    // 第二层把 passwd 删掉，并改写 hosts
    Whiteout("etc", "passwd"),
    File("etc/hosts", "127.0.0.1 localhost\n::1 localhost"),
  ])
  let result = apply_layers_with_diffs([layer0, layer1]) catch {
    err => fail(err.to_string())
  }
  assert_true(result.tree.get("/etc/passwd") is None)
  inspect(
    render_tree(result.tree),
    content=(
      #|/
      #|  etc/ [L0]
      #|    hosts (33 bytes) [L1]
      #|
    ),
  )
  let diff = result.diffs[1]
  assert_eq(diff.removed, ["/etc/passwd"])
  assert_eq(diff.modified, ["/etc/hosts"])
}

///|
/// README 里的逐层浏览示例。
async test "README layer browse" {
  let layer0 = build_tar([TarEntrySpec::File("app/main.js", "v1")])
  let layer1 = build_tar([TarEntrySpec::File("app/main.js", "v2-longer")])
  let views = browse_layers([layer0, layer1]) catch {
    err => fail(err.to_string())
  }
  assert_eq(views[0].tree.require("/app/main.js").size, 2)
  assert_eq(views[1].diff.modified, ["/app/main.js"])
  assert_eq(views[1].changed_paths(), ["/app/main.js"])
  let app = views[1].subtree("/app")
  assert_eq(app.size(), 2)
  inspect(
    render_tree(app),
    content=(
      #|/
      #|  app/ [L0]
      #|    main.js (9 bytes) [L1]
      #|
    ),
  )
}

///|
/// README 里的聚合档示例。
async test "README aggregate compare" {
  let l0 = build_tar([Dir("app"), File("app/main", "v1")])
  let l1 = build_tar([File("app/main", "v2-longer")])
  let l2 = build_tar([File("app/main", "v1")])
  let views = browse_layers([l0, l1, l2]) catch { err => fail(err.to_string()) }
  assert_eq(views[2].diff.modified, ["/app/main"])
  assert_eq(views[2].aggregate.modified, ["/app", "/app/main"])
  assert_eq(views[2].aggregate.removed, [])
  assert_eq(views[2].aggregate_size_delta(0), 0)
}
