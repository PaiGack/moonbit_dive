///|
/// 造一份三规则、两条失败的结论，用于输出测试。
fn failing_result() -> CheckResult raise {
  Ruleset::of_rules(
    [MaxImageSize(15), MinEfficiency(0.9), DenyPaths(["/node_modules/**"])],
    source="rules.json",
  ).check(covered_report(), covered_tree(), image="nginx.tar")
}

///|
/// 共用的小工具：一份「覆盖写入」镜像的报告与树。
fn covered_report() -> @image_analysis.Report raise {
  let (report, _) = @image_ci.covered_pair()
  report
}

///|
fn covered_tree() -> @layer_tree.FileTree raise {
  let (_, tree) = @image_ci.covered_pair()
  tree
}

///|
/// 文本报告：每条规则一行，失败带 reason，末尾给汇总。
test "text report snapshot" {
  let result = failing_result()
  assert_eq(
    result.to_text(),
    (
      #|image: nginx.tar
      #|rules: rules.json
      #|[FAIL] rule-1: maxImageSize <= 15 (observed 16 bytes, expected <= 15 bytes)
      #|        reason: observed 16 bytes exceeds the 15 bytes limit by 1 bytes
      #|[FAIL] rule-2: minEfficiency >= 0.9 (observed 38.5%, expected >= 90%)
      #|        reason: efficiency 38.5% is below the 90% floor; 10 bytes were wasted across layers
      #|[pass] rule-3: denyPaths 1 pattern(s) (observed 0 matching file(s), expected no file matches (/node_modules/**))
      #|1/3 rules passed, 2 failed
      #|gate: fail
      #|
    ),
  )
}

///|
/// JSON 输出：字段齐全，CI 能直接读 `passed` 与 `exitCode`。
test "json output shape" {
  let result = failing_result()
  let json = result.to_json()
  let text = json.stringify(indent=2)
  assert_true(text.contains("\"version\": 1"))
  assert_true(text.contains("\"source\": \"rules.json\""))
  assert_true(text.contains("\"image\": \"nginx.tar\""))
  assert_true(text.contains("\"passed\": false"))
  assert_true(text.contains("\"exitCode\": 1"))
  assert_true(text.contains("\"failed\": 2"))
  assert_true(text.contains("\"type\": \"maxImageSize\""))
  assert_true(text.contains("\"status\": \"fail\""))
  assert_true(text.contains("\"locations\""))
}

///|
/// CI 注解：失败出 `::error`，并通过出 `::notice`，最后给一行总结。
test "ci annotations" {
  let result = failing_result()
  let annotations = result.to_annotations()
  assert_true(
    annotations.contains(
      "::error file=<image>,title=rule-1::rule-1: maxImageSize <= 15",
    ),
  )
  assert_true(annotations.contains("::notice file=<image>,title=rule-3::"))
  assert_true(
    annotations.contains("::error title=image-size-gate::2/3 rules failed"),
  )
  // 注解里的换行必须转义，否则会被 workflow 解析器截断
  assert_false(
    annotations.contains(")\n::notice") is false &&
    annotations.contains("\n::notice"),
  )
}

///|
/// 全过时：exit code 0、gate pass、注解给一行通过总结。
test "passing output" {
  let result = Ruleset::of_rules([MaxImageSize(1024)]).check(
    covered_report(),
    covered_tree(),
    image="small.tar",
  )
  assert_eq(exit_code_of(result), exit_ok)
  assert_true(result.to_text().contains("gate: pass"))
  assert_true(
    result
    .to_annotations()
    .contains("::notice title=image-size-gate::all 1 rules passed"),
  )
}

///|
/// 规则非法走 exit 2，与「有规则失败」分开。
test "config error output" {
  let error = ConfigError::MissingRules
  assert_eq(exit_config_error, 2)
  let json = config_error_to_json(error, "broken.json").stringify(indent=2)
  assert_true(json.contains("\"exitCode\": 2"))
  assert_true(json.contains("non-empty"))
  let annotation = config_error_annotation(error, "broken.json")
  assert_true(
    annotation.has_prefix("::error file=<image>,title=rules-config::"),
  )
  assert_true(annotation.contains("broken.json"))
}
