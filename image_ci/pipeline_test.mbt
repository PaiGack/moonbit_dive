///|
/// 端到端：造一个 docker save tar → 加载 → 叠树 → 分析 → 门禁判定。
/// 走的是 `cmd/main` 里同一条链路，验证四个包能接上。
test "end to end: docker archive to gate verdict" {
  let archive = @image_ci.sample_docker_archive()
  let source = ImageSource::from_tar_bytes(archive, name="sample-image.tar") catch {
    err => fail(err.to_string())
  }
  assert_eq(source.layers.length(), 2)

  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = []
  for layer in source.layers {
    let raw = layer.raw_bytes() catch { err => fail(err.to_string()) }
    layers.push(raw)
  }
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }
  let report = @image_analysis.build_report(analysis, tree)
  // 两层各写 20 / 36 字节，其中 20 字节是覆盖掉的浪费
  assert_eq(report.final_file_bytes, 36)
  assert_eq(report.overwritten_wasted, 20)

  let ruleset = Ruleset::parse(
    (
      #|{
      #|  "ids": ["image-size", "efficiency", "no-node-modules", "app-file-size"],
      #|  "rules": [
      #|    { "type": "maxImageSize", "maxBytes": 4096 },
      #|    { "type": "minEfficiency", "score": 0.5 },
      #|    { "type": "denyPaths", "patterns": ["/node_modules/**"] },
      #|    { "type": "maxFileSize", "maxBytes": 10, "scope": { "path": "/app/**" } }
      #|  ]
      #|}
    ),
    source="rules.json",
  ) catch {
    err => fail(err.to_string())
  }
  let result = ruleset.check(report, tree, image="sample-image.tar")
  assert_eq(result.results.length(), 4)
  // 大小过、效率不过（35.7% < 50%）、node_modules 命中、/app/main.js 16 字节超 10
  assert_eq(result.passed_count(), 1)
  assert_eq(result.failed_count(), 3)
  assert_eq(exit_code_of(result), exit_rule_failed)
  assert_true(result.results[1].rule is MinEfficiency(_))
  assert_eq(result.results[2].locations[0], "/node_modules/pkg/index.js")
  assert_eq(result.results[3].locations[0], "/app/main.js")
}

///|
/// 同一个镜像换一套宽松规则应当全过，退出码回到 0。
test "end to end: relaxed rules pass" {
  let source = ImageSource::from_tar_bytes(
    @image_ci.sample_docker_archive(),
    name="sample-image.tar",
  ) catch {
    err => fail(err.to_string())
  }
  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = []
  for layer in source.layers {
    let raw = layer.raw_bytes() catch { err => fail(err.to_string()) }
    layers.push(raw)
  }
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }
  let report = @image_analysis.build_report(analysis, tree)
  let ruleset = Ruleset::of_rules([
    MaxImageSize(4096),
    MaxLayerSize(4096),
    MaxWastedSize(4096),
    MinEfficiency(0.3),
  ])
  let result = ruleset.check(report, tree)
  assert_true(result.all_passed())
  assert_eq(exit_code_of(result), exit_ok)
}
