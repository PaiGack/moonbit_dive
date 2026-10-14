///|
/// README 里的示例原样跑一遍，防止文档漂移。
test "README example runs as written" {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
    @layer_tree.TarEntrySpec::Dir("node_modules"),
    @layer_tree.TarEntrySpec::File("node_modules/pkg/index.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
    @layer_tree.TarEntrySpec::File(
      "node_modules/pkg/index.js", "0123456789abcdefghij",
    ),
  ])

  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = [layer0, layer1]
  let analysis = @dive_analysis.analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }
  let report = @dive_analysis.build_report(analysis, tree)

  let ruleset = Ruleset::parse(
    (
      #|{ "rules": [
      #|  { "type": "maxImageSize", "maxBytes": 4096 },
      #|  { "type": "minEfficiency", "score": 0.5 },
      #|  { "type": "denyPaths", "patterns": ["/app/node_modules/**", "/node_modules/**"] }
      #|] }
    ),
  ) catch {
    err => fail(err.to_string())
  }

  let result = ruleset.check(report, tree, image="demo.tar")
  assert_eq(result.passed_count(), 1)
  assert_eq(result.failed_count(), 2)
  assert_eq(exit_code_of(result), 1)
  assert_true(result.results[2].locations[0].contains("node_modules"))
}
