///|
/// 把分析结果压成详情数据源：每个路径的版本数与累计字节都要有落点。
test "detail_source_of maps analysis into per-path entries" {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main", "xxxx"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "yyyyyyyy"),
  ])
  let layers : Array[BytesView] = [l0, l1]
  let decompressed = @layer_tree.decompress_layers(layers) catch {
    err => fail(err.to_string())
  }
  let (analysis, report) = analysis_of_decompressed(decompressed).unwrap()
  let source = detail_source_of(analysis, report)
  // `/app/main` 被写了两次：4 字节 → 8 字节，精确值来自逐路径版本表
  // （不是「最终大小 × 版本数」那种近似）
  let entry = source.entries.get("/app/main").unwrap()
  assert_eq(entry.versions, 2)
  assert_eq(entry.min_bytes, 4)
  assert_eq(entry.cumulative, 12)
  assert_eq(entry.size, 8)
  assert_true(source.total > 0)
}

///|
/// 面板上下两个数必须自洽（issue #72 的验收）：
///
/// - 概览行的 `wasted` = `Σ` 表里每行的 `size`（都是 `cumulative - min` 口径）
/// - 表里的行数与排序跟 `report.inefficient_paths` 一一对应：
///   面板与 `--efficiency` 视图看的是同一批数字，不各自算一套
test "detail source waste total equals the sum of the inefficient rows" {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main", "xxxx"),
    @layer_tree.TarEntrySpec::File("app/util", "yy"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "yyyyyyyy"),
  ])
  let layers : Array[BytesView] = [l0, l1]
  let decompressed = @layer_tree.decompress_layers(layers) catch {
    err => fail(err.to_string())
  }
  let (analysis, report) = analysis_of_decompressed(decompressed).unwrap()
  let source = detail_source_of(analysis, report)
  let mut sum = 0
  for _, (_, _, size) in source.top_wasteful {
    sum = sum + size
  }
  assert_eq(source.wasted, sum)
  // 与报告里那张表逐行同源（同一批 path / size）
  assert_eq(source.top_wasteful.length(), report.inefficient_paths.length())
  for index, row in report.inefficient_paths {
    let (path, versions, size) = source.top_wasteful[index]
    assert_eq(path, row.path)
    assert_eq(versions, row.versions)
    assert_eq(size, row.cumulative_bytes - row.min_bytes)
  }
  // 面板的 `wasted` 是 dive 口径，不是「真实丢掉的字节」
  assert_eq(
    source.wasted,
    report.efficiency.cumulative_bytes - report.efficiency.min_bytes,
  )
}

///|
/// 空层集合下 `analysis_of_decompressed` 也要给出结果（不抛），详情源为空但可用。
test "analysis_of_decompressed tolerates empty input" {
  let layers : Array[BytesView] = []
  let decompressed = @layer_tree.decompress_layers(layers) catch {
    err => fail(err.to_string())
  }
  let pair = analysis_of_decompressed(decompressed)
  assert_true(pair is Some(_))
  let (analysis, report) = pair.unwrap()
  let source = detail_source_of(analysis, report)
  assert_eq(source.total, report.final_file_bytes)
  assert_eq(source.wasted, report.overwritten_wasted + report.deleted_wasted)
}

///|
/// 详情数据源与视图共用同一批解压产物：一次解压，两条链路。
///
/// issue #52 的验收条件在 TUI 这一侧的样子——`AppState::new` 拿到的视图
/// 与 `analysis_of_decompressed` 出的详情，必须来自同一个 `DecompressedLayers`，
/// 而不是各自解压一遍。解压次数由 `decompressed` 钉死。
test "views and details share one decompression" {
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main", "xxxx"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "yyyyyyyy"),
  ])
  let layers : Array[BytesView] = [l0, l1]
  let decompressed = @layer_tree.decompress_layers(layers) catch {
    err => fail(err.to_string())
  }
  assert_eq(decompressed.decompressed, 2)
  let views = @layer_tree.browse_decompressed(decompressed)
  let (analysis, report) = analysis_of_decompressed(decompressed).unwrap()
  let source = detail_source_of(analysis, report)
  // 视图看的是最后一层的树，详情看的是跨层统计：数字必须对得上
  // （`/app` 与 `/app/main` 两个节点）
  assert_eq(views[1].tree.size(), 2)
  assert_eq(source.entries.get("/app/main").unwrap().versions, 2)
  assert_eq(source.total, report.final_file_bytes)
}
