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
async fn analyze_fixture(
  layers : Array[Bytes],
  media_types~ : Array[String] = [],
) -> (@layer_tree.FileTree, Analysis) {
  let tree = @layer_tree.FileTree::new()
  let views : Array[BytesView] = layers.map(fn(layer) { (layer : BytesView) })
  let analysis = analyze_layers(tree, views, media_types~) catch {
    err => fail("analysis should succeed: \{err}")
  }
  (tree, analysis)
}

///|
async test "single layer image wastes nothing" {
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
async test "overwriting a file counts the old bytes as waste" {
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
async test "whiteout charges the deleted bytes as waste" {
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
async test "whiteout on a directory charges its whole subtree" {
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
async test "opaque directory erases previous content but keeps the new writes" {
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
  assert_eq(tree.require("/etc/new.conf").info.size, 2)
  assert_eq(analysis.final_file_bytes, 2)
  assert_eq(analysis.usages[1].erased_bytes, 15)
  assert_eq(analysis.deleted_wasted, 15)
  assert_eq(analysis.wasted_bytes(), 15)
}

///|
async test "same-layer rewrites only count once" {
  // 同一层里写两次同名路径：后一次覆盖前一次，同层内的浪费不被单列，
  // 树上和总量都以最后一次为准
  let (tree, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::File("dup", "12345"),
      @layer_tree.TarEntrySpec::File("dup", "1234567890"),
    ]),
  ])
  assert_eq(tree.require("/dup").info.size, 10)
  assert_eq(analysis.final_file_bytes, 10)
  assert_eq(analysis.usages[0].written_bytes, 10)
  assert_eq(analysis.usages[0].added_paths, 1)
  assert_eq(analysis.usages[0].overwritten_paths, 0)
}

///|
async test "directories and links do not add bytes" {
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
async test "gzip layers are decompressed before accounting" {
  let plain = layer_fixture([@layer_tree.TarEntrySpec::File("a", "0123456789")])
  let gzipped = @layer_tree.gzip_compress(plain)
  let (_, analysis) = analyze_fixture([gzipped], media_types=[
    "application/vnd.oci.image.layer.v1.tar+gzip",
  ])
  assert_eq(analysis.final_file_bytes, 10)
  assert_eq(analysis.wasted_bytes(), 0)
}

///|
async test "waste ranking lists the worst paths first" {
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
async test "analyze_decompressed agrees with analyze_layers" {
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
async test "analyze fails loudly on a broken tar" {
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

///|
/// 进度回调按层触发，从 0 开始、到 `total - 1` 结束（issue #122）。
///
/// 主链路靠它把「下载完之后到底在干什么」打到 stderr；回调本身不参与记账，
/// 所以顺带钉住「加了回调结果不变」。
async test "layer progress callback fires for every layer in order" {
  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = [
    layer_fixture([@layer_tree.TarEntrySpec::File("a", "1")]),
    layer_fixture([@layer_tree.TarEntrySpec::File("b", "22")]),
    layer_fixture([@layer_tree.TarEntrySpec::File("c", "333")]),
  ]
  let seen = []
  let record : (Int32, Int32) -> Unit = fn(index, total) {
    seen.push((index, total))
  }
  let analysis = analyze_layers(tree, layers, on_layer=Some(record)) catch {
    err => fail(err.to_string())
  }
  assert_eq(seen, [(0, 3), (1, 3), (2, 3)])
  assert_eq(analysis.final_file_bytes, 6)
}

///|
/// 只抹掉、没覆盖任何东西的一层：用户账扣的是抹掉的那些字节（issue #122）。
async test "opaque erase is charged to the user exactly once" {
  let (_, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("app"),
      @layer_tree.TarEntrySpec::File("app/old.bin", "0123456789"),
    ]),
    layer_fixture([
      @layer_tree.TarEntrySpec::File("app/.wh..wh..opq", ""),
      @layer_tree.TarEntrySpec::File("app/new.bin", "01234"),
    ]),
  ])
  // 第 1 层写了 5 字节，抹掉 old.bin 的 10：净写入是 -5（夹到 0）
  assert_eq(analysis.usages[1].written_bytes, 5)
  assert_eq(analysis.usages[1].erased_bytes, 10)
  assert_eq(analysis.deleted_wasted, 10)
}

///|
/// 覆盖与 opaque 抹掉同时出现时，两栏互不重叠地各扣一次（issue #122）。
///
/// 报告里的 `user written` 是「净写入」：每层 `written - wasted - erased`。
/// 漏掉 `erased`，被整目录抹掉的内容就会被错算成用户写进去的字节。
async test "overwrite plus opaque does not double charge the user" {
  let (_, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("app"),
      @layer_tree.TarEntrySpec::File("app/keep.bin", "0123456789"),
      @layer_tree.TarEntrySpec::File("app/gone.bin", "0123456789"),
    ]),
    layer_fixture([
      @layer_tree.TarEntrySpec::File("app/keep.bin", "01234"),
      @layer_tree.TarEntrySpec::File("app/.wh..wh..opq", ""),
      @layer_tree.TarEntrySpec::File("app/fresh.bin", "01"),
    ]),
  ])
  let usage = analysis.usages[1]
  // 第 1 层写了 7 字节：覆盖 keep.bin 的 10 进 `wasted`，抹掉 gone.bin 的 20
  // 进 `erased`；净写入 7 - 10 - 20 是负数，夹到 0
  assert_eq(usage.written_bytes, 7)
  assert_eq(usage.erased_bytes, 20)
  assert_eq(usage.wasted_bytes, 10)
  assert_eq(analysis.user_bytes(), 0)
  assert_eq(analysis.overwritten_wasted, 10)
}
