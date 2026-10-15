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
  let (analysis, report) = analysis_of_layers(layers).unwrap()
  let source = detail_source_of(analysis, report)
  // `/app/main` 被写了两次
  let entry = source.entries.get("/app/main").unwrap()
  assert_eq(entry.versions, 2)
  // 累计 = 最终大小 × 版本数（口径见 model.mbt 注释），最小 = 最终大小
  assert_eq(entry.min_bytes, 8)
  assert_eq(entry.cumulative, 16)
  assert_true(source.total > 0)
}

///|
/// 空层集合下 `analysis_of_layers` 也要给出结果（不抛），详情源为空但可用。
test "analysis_of_layers tolerates empty input" {
  let layers : Array[BytesView] = []
  let pair = analysis_of_layers(layers)
  assert_true(pair is Some(_))
  let (analysis, report) = pair.unwrap()
  let source = detail_source_of(analysis, report)
  assert_eq(source.total, report.final_file_bytes)
  assert_eq(source.wasted, report.overwritten_wasted + report.deleted_wasted)
}
