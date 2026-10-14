///|
/// README 里的示例：多层 tar 的 whiteout 与 diff。
test "README example" {
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
