///|
/// 判等口径对齐 dive 的 `FileInfo::Compare`：`(kind, mode, uid, gid)` 全等才算
/// `Unmodified`；本仓在这之上多了一条内容指纹（同大小不同内容也能认出来）。
///
/// 这一组用例钉的是「跑一遍原版、再跑一遍本仓，结论一致」这件事，
/// 三种过去会分叉的场景各一条。
///
/// 造两层 tar 并把逐层 diff 取回来（走浏览链路，内容摘要一并带上）。
fn diff_of_layers(layer0 : Bytes, layer1 : Bytes) -> @layer_tree.Diff noraise {
  let views = try @layer_tree.browse_layers([layer0, layer1]) catch {
    err => abort("layers should browse: \{err.to_string()}")
  } noraise {
    views => views
  }
  views[1].diff
}

///|
test "same size and same mtime but different bytes is modified" {
  // 两个内容长度一样、mtime 一样，只有字节不同——原版靠内容哈希认出来，
  // 本仓靠扫描出来的 sha256 认出来；旧口径会判 Unmodified。
  // 元数据四项（kind/mode/uid/gid）与 size 全都一样，这一条只可能靠内容认定
  let builder0 = @layer_tree.TarBuilder::new()
  builder0.add_file("app/build.bin", "AAAA", mtime=1700000000)
  let builder1 = @layer_tree.TarBuilder::new()
  builder1.add_file("app/build.bin", "BBBB", mtime=1700000000)
  let layer0 = builder0.finish()
  let layer1 = builder1.finish()

  let tree = @layer_tree.FileTree::new()
  try @layer_tree.apply_layer(tree, layer0, 0) catch {
    err => abort("layer 0 should apply: \{err.to_string()}")
  } noraise {
    _ => ()
  }
  let before = tree.snapshot()
  try @layer_tree.apply_layer(tree, layer1, 1) catch {
    err => abort("layer 1 should apply: \{err.to_string()}")
  } noraise {
    _ => ()
  }
  let after = tree.snapshot()
  // 元数据与 size 全都一样：光比元数据会说「没动过」
  let old_node = before.require("/app/build.bin")
  let new_node = after.require("/app/build.bin")
  assert_eq(old_node.size, new_node.size)
  assert_eq(old_node.mode, new_node.mode)
  assert_eq(old_node.uid, new_node.uid)
  assert_eq(old_node.gid, new_node.gid)
  assert_eq(old_node.mtime, new_node.mtime)

  // 补上内容摘要后，diff 认得出这条改写
  before.scan_content([layer0])
  after.scan_content([layer0, layer1])
  let diff = @layer_tree.diff_snapshots(before, after, 0, 1)
  assert_eq(diff.modified, ["/app/build.bin"])
  assert_true(diff.added.is_empty())
}

///|
test "identical bytes with a new mtime is unmodified" {
  // `COPY` 会把时间戳刷新，但内容没变：原版不看 mtime，本仓也不看
  let builder0 = @layer_tree.TarBuilder::new()
  builder0.add_file("app/main.js", "same", mtime=100)
  let builder1 = @layer_tree.TarBuilder::new()
  builder1.add_file("app/main.js", "same", mtime=999)
  let layer0 = builder0.finish()
  let layer1 = builder1.finish()
  let diff = diff_of_layers(layer0, layer1)
  assert_true(diff.modified.is_empty())
  assert_true(diff.added.is_empty())
  assert_true(diff.removed.is_empty())
}

///|
test "a mode change alone is modified" {
  let builder0 = @layer_tree.TarBuilder::new()
  builder0.add_file("bin/run", "x", mode=0o644)
  let builder1 = @layer_tree.TarBuilder::new()
  builder1.add_file("bin/run", "x", mode=0o755)
  let layer0 = builder0.finish()
  let layer1 = builder1.finish()
  assert_eq(diff_of_layers(layer0, layer1).modified, ["/bin/run"])
}

///|
test "an ownership change alone is modified" {
  let builder0 = @layer_tree.TarBuilder::new()
  builder0.add_file("etc/hosts", "x", uid=0, gid=0)
  let builder1 = @layer_tree.TarBuilder::new()
  builder1.add_file("etc/hosts", "x", uid=1000, gid=1000)
  let layer0 = builder0.finish()
  let layer1 = builder1.finish()
  assert_eq(diff_of_layers(layer0, layer1).modified, ["/etc/hosts"])
}

///|
test "an ownership change on a directory is modified" {
  let builder0 = @layer_tree.TarBuilder::new()
  builder0.add_header("var", 0, entry_type=b'5', mode=0o755, uid=0, gid=0)
  let builder1 = @layer_tree.TarBuilder::new()
  builder1.add_header("var", 0, entry_type=b'5', mode=0o755, uid=7, gid=7)
  assert_eq(diff_of_layers(builder0.finish(), builder1.finish()).modified, [
    "/var",
  ])
}

///|
test "tar parsing reads uid and gid from the header" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_header("owned.txt", 0, uid=1234, gid=5678)
  let entries = @layer_tree.parse_tar_entries(builder.finish()) catch {
    err => fail("tar should parse: \{err.to_string()}")
  }
  assert_eq(entries[0].uid, 1234)
  assert_eq(entries[0].gid, 5678)
}

///|
test "content_scan fingerprints every regular file" {
  let raw = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("etc"),
    @layer_tree.TarEntrySpec::File("etc/hosts", "hello"),
  ])
  let tree = @layer_tree.FileTree::new()
  @layer_tree.apply_layer(tree, raw, 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  tree.scan_content([raw])
  // sha256("hello")
  assert_eq(
    tree.require("/etc/hosts").digest.unwrap().hash,
    Some("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"),
  )
  // 目录没有内容字节，摘要留空
  assert_eq(tree.require("/etc").digest.unwrap().hash, None)
}

///|
test "digest tracks how many times a path was written" {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "v1"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "v2"),
  ])
  let tree = @layer_tree.FileTree::new()
  @layer_tree.apply_layer(tree, layer0, 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  @layer_tree.apply_layer(tree, layer1, 1) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  tree.scan_content([layer0, layer1])
  let digest = tree.require("/app/main").digest.unwrap()
  assert_eq(digest.changes, 1)
  // 终值是第 1 层写的
  assert_eq(tree.require("/app/main").files.length(), 1)
  assert_eq(tree.require("/app/main").files[0].layer, 1)
}

///|
test "content_changes finds rewritten paths and drops deleted ones" {
  let before = @layer_tree.content_scan(
    @layer_tree.build_tar([
      @layer_tree.TarEntrySpec::File("a", "same"),
      @layer_tree.TarEntrySpec::File("b", "old"),
    ]),
  )
  let after = @layer_tree.content_scan(
    @layer_tree.build_tar([
      @layer_tree.TarEntrySpec::File("a", "same"),
      @layer_tree.TarEntrySpec::File("b", "new"),
    ]),
  )
  // 只有 b 变了（a 的摘要一样，不算变化）
  assert_eq(@layer_tree.content_changes(before, after), ["/b"])
}

///|
/// 逐层浏览默认会按 tar 算一遍内容摘要：不必自己调 `scan_content`，
/// 「同大小、同 mtime、内容不同」在这一档就认得出来。
test "browse_layers compares contents by default" {
  let builder0 = @layer_tree.TarBuilder::new()
  builder0.add_file("app/build.bin", "AAAA", mtime=1700000000)
  let builder1 = @layer_tree.TarBuilder::new()
  builder1.add_file("app/build.bin", "BBBB", mtime=1700000000)
  let views = @layer_tree.browse_layers([builder0.finish(), builder1.finish()]) catch {
    err => fail("layers should browse: \{err.to_string()}")
  }
  assert_eq(views[1].diff.modified, ["/app/build.bin"])
}

///|
/// `content_hashes = false` 关掉哈希：只剩元数据 + size 可比，
/// 「同大小不同内容」就认不出来了——这是省掉那一遍全量读取的代价。
test "browse_decompressed can skip content hashes" {
  let builder0 = @layer_tree.TarBuilder::new()
  builder0.add_file("app/build.bin", "AAAA", mtime=1700000000)
  let builder1 = @layer_tree.TarBuilder::new()
  builder1.add_file("app/build.bin", "BBBB", mtime=1700000000)
  let decompressed = @layer_tree.decompress_layers([
    builder0.finish(),
    builder1.finish(),
  ]) catch {
    err => fail("layers should decompress: \{err.to_string()}")
  }
  let views = @layer_tree.browse_decompressed(
    decompressed,
    content_hashes=false,
  )
  assert_true(views[1].diff.modified.is_empty())
  // 快照上没有摘要
  assert_true(views[1].tree.require("/app/build.bin").digest is None)
}

///|
/// 两种档位的「同大小不同内容」判据一致：都靠内容指纹，
/// 不靠 `size` 与 `mtime` 这些看不出字节的东西。
test "size-only differences are still detected without content hashes" {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "v1"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "v2-longer"),
  ])
  let decompressed = @layer_tree.decompress_layers([layer0, layer1]) catch {
    err => fail("layers should decompress: \{err.to_string()}")
  }
  let views = @layer_tree.browse_decompressed(
    decompressed,
    content_hashes=false,
  )
  assert_eq(views[1].diff.modified, ["/app/main"])
}
