///|
/// README 里的示例原样跑一遍，防止文档漂移。

///|
test "README example runs as written" {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
  ])

  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = [layer0, layer1]
  let analysis = analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }
  assert_eq(analysis.final_file_bytes, 16)
  assert_eq(analysis.overwritten_wasted, 10)
  assert_eq(analysis.wasted_bytes(), 10)

  let report = build_report(analysis, tree)
  assert_eq(report.efficiency.min_bytes, 10)
  assert_eq(report.efficiency.cumulative_bytes, 26)
  assert_true(report.efficiency.score() < 0.4)
}
