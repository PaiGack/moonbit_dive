///|
/// 测试夹具：手工造层 tar 的薄封装。
///
/// 生产代码只吃「已解压的层」，写 tar 的能力来自 P2（`TarBuilder` 是测试专用），
/// 这里只把常用写法收短，避免每个测试里重复 map。
/// 白盒测试：分析过程要读内部账本（`PathSize` / `LayerUsage`），放在包内写。
fn layer_fixture(entries : Array[@layer_tree.TarEntrySpec]) -> Bytes {
  @layer_tree.build_tar(entries)
}

///|
/// 把一组层 tar 跑成 `BytesView`，再交给分析。
fn analyze_fixture(
  layers : Array[Bytes],
  media_types~ : Array[String] = [],
) -> (@layer_tree.FileTree, Analysis) raise {
  let tree = @layer_tree.FileTree::new()
  let views : Array[BytesView] = layers.map(fn(layer) { (layer : BytesView) })
  let analysis = analyze_layers(tree, views, media_types~) catch {
    err => fail("analysis should succeed: \{err}")
  }
  (tree, analysis)
}

///|
test "single layer image wastes nothing" {
  let (tree, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("etc"),
      @layer_tree.TarEntrySpec::File("etc/hosts", "127.0.0.1 localhost"),
      @layer_tree.TarEntrySpec::File("etc/passwd", "root:x:0:0"),
    ]),
  ])
  // 19 + 10 = 29；目录不占字节
  assert_eq(analysis.final_file_bytes, 29)
  assert_eq(analysis.wasted_bytes(), 0)
  assert_eq(analysis.overwritten_wasted, 0)
  assert_eq(analysis.deleted_wasted, 0)
  assert_eq(analysis.layers, 1)
  assert_eq(analysis.final_paths, 3)
  // 只有一层，没有可浪费的空间
  let usage = analysis.usages[0]
  assert_eq(usage.added_paths, 3)
  assert_eq(usage.overwritten_paths, 0)
  assert_eq(usage.written_bytes, 29)
  assert_eq(tree.size(), 3)
}

///|
test "overwriting a file counts the old bytes as waste" {
  let (_, analysis) = analyze_fixture([
    layer_fixture([@layer_tree.TarEntrySpec::File("app/main.js", "12345")]),
    layer_fixture([@layer_tree.TarEntrySpec::File("app/main.js", "1234567890")]),
  ])
  assert_eq(analysis.final_file_bytes, 10)
  assert_eq(analysis.overwritten_wasted, 5)
  assert_eq(analysis.deleted_wasted, 0)
  let usage = analysis.usages[1]
  assert_eq(usage.overwritten_paths, 1)
  assert_eq(usage.added_paths, 0)
  assert_eq(usage.written_bytes, 10)
  assert_eq(usage.wasted_bytes, 5)
  let size = analysis.path_size("/app/main.js").unwrap()
  assert_eq(size.size, 10)
  assert_eq(size.wasted_bytes, 5)
  assert_eq(size.writes, 2)
  assert_false(size.deleted)
  assert_eq(size.current_layer, Some(1))
}

///|
test "whiteout charges the deleted bytes as waste" {
  let (tree, analysis) = analyze_fixture([
    layer_fixture([@layer_tree.TarEntrySpec::File("big", "0123456789")]),
    layer_fixture([@layer_tree.TarEntrySpec::Whiteout("", "big")]),
  ])
  assert_eq(analysis.final_file_bytes, 0)
  assert_eq(analysis.deleted_wasted, 10)
  assert_eq(analysis.overwritten_wasted, 0)
  assert_eq(analysis.usages[1].deleted_paths, 1)
  assert_eq(analysis.usages[1].wasted_bytes, 10)
  assert_true(tree.get("/big") is None)
  let size = analysis.path_size("/big").unwrap()
  assert_eq(size.size, 0)
  assert_true(size.deleted)
  assert_eq(size.current_layer, None)
}

///|
test "whiteout on a directory charges its whole subtree" {
  let (_, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("var"),
      @layer_tree.TarEntrySpec::Dir("var/log"),
      @layer_tree.TarEntrySpec::File("var/log/app.log", "0123456789"),
      @layer_tree.TarEntrySpec::File("var/keep", "abcd"),
    ]),
    layer_fixture([@layer_tree.TarEntrySpec::Whiteout("", "var")]),
  ])
  assert_eq(analysis.final_file_bytes, 0)
  // 子树里两个文件共 10 + 4 = 14 字节全部作废
  assert_eq(analysis.deleted_wasted, 14)
  // var、var/log、var/log/app.log、var/keep 四条路径一起消失
  assert_eq(analysis.usages[1].deleted_paths, 4)
}

///|
test "opaque directory erases previous content but keeps the new writes" {
  let (tree, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("etc"),
      @layer_tree.TarEntrySpec::File("etc/old.conf", "0123456789"),
      @layer_tree.TarEntrySpec::File("etc/stale.conf", "abcde"),
    ]),
    layer_fixture([
      @layer_tree.TarEntrySpec::Opaque("etc"),
      @layer_tree.TarEntrySpec::File("etc/new.conf", "xy"),
    ]),
  ])
  assert_true(tree.get("/etc/old.conf") is None)
  assert_true(tree.get("/etc/stale.conf") is None)
  assert_eq(tree.require("/etc/new.conf").size, 2)
  assert_eq(analysis.final_file_bytes, 2)
  assert_eq(analysis.usages[1].erased_bytes, 15)
  assert_eq(analysis.deleted_wasted, 15)
  assert_eq(analysis.wasted_bytes(), 15)
}

///|
test "same-layer rewrites only count once" {
  // 同一层里写两次同名路径：后一次覆盖前一次，同层内的浪费不被单列，
  // 树上和总量都以最后一次为准
  let (tree, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::File("dup", "12345"),
      @layer_tree.TarEntrySpec::File("dup", "1234567890"),
    ]),
  ])
  assert_eq(tree.require("/dup").size, 10)
  assert_eq(analysis.final_file_bytes, 10)
  assert_eq(analysis.usages[0].written_bytes, 10)
  assert_eq(analysis.usages[0].added_paths, 1)
  assert_eq(analysis.usages[0].overwritten_paths, 0)
}

///|
test "directories and links do not add bytes" {
  let (_, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("bin"),
      @layer_tree.TarEntrySpec::File("bin/sh", "12345"),
      @layer_tree.TarEntrySpec::Symlink("bin/bash", "sh"),
      @layer_tree.TarEntrySpec::Hardlink("bin/sh-copy", "bin/sh"),
    ]),
  ])
  assert_eq(analysis.final_file_bytes, 5)
  // 目录、软链、硬链都算路径，但不吃字节
  assert_eq(analysis.final_paths, 4)
  assert_eq(analysis.usages[0].added_paths, 4)
  assert_eq(analysis.usages[0].written_bytes, 5)
}

///|
test "gzip layers are decompressed before accounting" {
  let plain = layer_fixture([@layer_tree.TarEntrySpec::File("a", "0123456789")])
  let gzipped = @layer_tree.gzip_compress(plain)
  let (_, analysis) = analyze_fixture([gzipped], media_types=[
    "application/vnd.oci.image.layer.v1.tar+gzip",
  ])
  assert_eq(analysis.final_file_bytes, 10)
  assert_eq(analysis.wasted_bytes(), 0)
}

///|
test "waste ranking lists the worst paths first" {
  let (_, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::File("small", "ab"),
      @layer_tree.TarEntrySpec::File("large", "0123456789"),
    ]),
    layer_fixture([
      @layer_tree.TarEntrySpec::File("small", "abc"),
      @layer_tree.TarEntrySpec::File("large", "0123456789abcdef"),
    ]),
  ])
  let ranking = analysis.waste_ranking()
  assert_eq(ranking.length(), 2)
  assert_eq(ranking[0].wasted_bytes, 10)
  assert_eq(ranking[1].wasted_bytes, 2)
  assert_eq(analysis.waste_ranking(limit=1).length(), 1)
}

///|
/// 「先解压再记账」与 `analyze_layers` 必须给出同一份账。
///
/// issue #52 合并了两条链路，验收要求「报告数字与合并前一致」：
/// 这里把同一批层分别喂给两条入口，逐字段比对，合并只许省掉一次解压，
/// 不许动任何数字。
test "analyze_decompressed agrees with analyze_layers" {
  let layers : Array[BytesView] = [
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("app"),
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
      @layer_tree.TarEntrySpec::File("app/README.md", "hello"),
    ]),
    @layer_tree.gzip_compress(
      layer_fixture([
        @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
      ]),
    ),
    layer_fixture([@layer_tree.TarEntrySpec::Whiteout("app", "README.md")]),
  ]
  let media_types = [
    "application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.v1.tar+gzip",
    "application/vnd.oci.image.layer.v1.tar",
  ]
  let direct_tree = @layer_tree.FileTree::new()
  let direct = analyze_layers(direct_tree, layers, media_types~) catch {
    err => fail(err.to_string())
  }
  let merged_tree = @layer_tree.FileTree::new()
  let decompressed = @layer_tree.decompress_layers(layers, media_types~) catch {
    err => fail(err.to_string())
  }
  let merged = analyze_decompressed(merged_tree, decompressed) catch {
    err => fail(err.to_string())
  }
  // 统计本身逐字段一致
  assert_eq(merged.layers, direct.layers)
  assert_eq(merged.final_file_bytes, direct.final_file_bytes)
  assert_eq(merged.final_paths, direct.final_paths)
  assert_eq(merged.overwritten_wasted, direct.overwritten_wasted)
  assert_eq(merged.deleted_wasted, direct.deleted_wasted)
  assert_eq(merged.total_bytes(), direct.total_bytes())
  assert_eq(merged.usages, direct.usages)
  assert_eq(merged.versions, direct.versions)
  // 报告也逐字段一致（含 hotspots 用的那棵树）
  let direct_report = build_report(direct, direct_tree)
  let merged_report = build_report(merged, merged_tree)
  assert_eq(merged_report, direct_report)
  assert_eq(
    render_text_report(merged_report),
    render_text_report(direct_report),
  )
}

///|
test "analyze fails loudly on a broken tar" {
  let tree = @layer_tree.FileTree::new()
  let broken : Array[BytesView] = [b"\x00\x01\x02"]
  let result = try {
    ignore(analyze_layers(tree, broken))
    None
  } catch {
    err => Some(err)
  }
  assert_true(result is Some(_))
}
