///|
/// maxImageSize：上限之上判 fail，之下判 pass。
async test "maxImageSize" {
  let (report, tree) = @image_ci.covered_fixture()
  // 当前占用 16 字节
  let ok = Ruleset::of_rules([MaxImageSize(16)]).check(report, tree)
  assert_true(ok.all_passed())
  assert_eq(ok.results[0].observed, "16 bytes")

  let bad = Ruleset::of_rules([MaxImageSize(15)]).check(report, tree)
  assert_false(bad.all_passed())
  assert_eq(bad.results[0].id, "rule-1")
  assert_true(bad.results[0].reason.contains("exceeds the 15 bytes limit"))
}

///|
/// maxLayerSize：看单层最大写入，并指认出超限的那一层。
async test "maxLayerSize" {
  let (report, tree) = @image_ci.covered_fixture()
  // L0 写 10 字节，L1 写 16 字节（层 tar 实际写入量）
  let ok = Ruleset::of_rules([MaxLayerSize(64)]).check(report, tree)
  assert_true(ok.all_passed())

  let bad = Ruleset::of_rules([MaxLayerSize(8)]).check(report, tree)
  assert_false(bad.all_passed())
  assert_eq(bad.results[0].locations[0], "L1")
  assert_true(bad.results[0].reason.contains("layer L1"))
}

///|
/// maxWastedSize：覆盖掉的旧字节算浪费。
async test "maxWastedSize" {
  let (report, tree) = @image_ci.covered_fixture()
  // 10 字节被覆盖
  let ok = Ruleset::of_rules([MaxWastedSize(10)]).check(report, tree)
  assert_true(ok.all_passed())
  assert_eq(ok.results[0].observed, "10 bytes")

  let bad = Ruleset::of_rules([MaxWastedSize(9)]).check(report, tree)
  assert_false(bad.all_passed())
}

///|
/// minEfficiency：分数按 min / cumulative 算，10/26 约 38%。
async test "minEfficiency" {
  let (report, tree) = @image_ci.covered_fixture()
  let ok = Ruleset::of_rules([MinEfficiency(0.3)]).check(report, tree)
  assert_true(ok.all_passed())
  assert_eq(ok.results[0].observed, "38.5%")

  let bad = Ruleset::of_rules([MinEfficiency(0.5)]).check(report, tree)
  assert_false(bad.all_passed())
  assert_true(bad.results[0].reason.contains("below the 50% floor"))
}

///|
/// denyPaths：黑名单命中文件即失败，命中路径进 locations。
async test "denyPaths" {
  let (report, tree) = @image_ci.fat_fixture()
  let ok = Ruleset::of_rules([DenyPaths(["/usr/**", "/node_modules/**"])]).check(
    report, tree,
  )
  // node_modules 在根下，`/node_modules/**` 应该命中
  assert_false(ok.all_passed())
  assert_eq(ok.results[0].locations[0], "/node_modules/pkg/index.js")

  let clean = Ruleset::of_rules([DenyPaths(["/usr/**"])]).check(report, tree)
  assert_true(clean.all_passed())
}

///|
/// allowPaths：白名单外的文件即失败。
async test "allowPaths" {
  let (report, tree) = @image_ci.fat_fixture()
  // 只允许 /app.js 与 /node_modules 下的东西
  let ok = Ruleset::of_rules([AllowPaths(["/app.js", "/node_modules/**"])]).check(
    report, tree,
  )
  assert_true(ok.all_passed())

  let bad = Ruleset::of_rules([AllowPaths(["/app.js"])]).check(report, tree)
  assert_false(bad.all_passed())
  assert_eq(bad.results[0].locations[0], "/node_modules/pkg/index.js")
}

///|
/// maxFileSize：不带范围看全镜像，带范围只看子树；递归开关生效。
async test "maxFileSize" {
  let (report, tree) = @image_ci.fat_fixture()
  // /node_modules/pkg/index.js 当前 20 字节，/app.js 5 字节
  let ok = Ruleset::of_rules([MaxFileSize(20, None)]).check(report, tree)
  assert_true(ok.all_passed())
  assert_eq(ok.results[0].observed, "largest 20 bytes")

  let bad = Ruleset::of_rules([MaxFileSize(19, None)]).check(report, tree)
  assert_false(bad.all_passed())
  assert_true(bad.results[0].reason.contains("/node_modules/pkg/index.js"))

  // 限定 /app.js 目录（不存在该目录）时，范围内没有文件 → 视为通过
  let scoped = Ruleset::of_rules([
    MaxFileSize(1, Some(PathFilter::new(PathPattern::compile("/srv/**")))),
  ]).check(report, tree)
  assert_true(scoped.all_passed())
}

///|
/// 混合规则：一条失败即整体失败，汇总计数正确。
async test "mixed rules and summary" {
  let (report, tree) = @image_ci.covered_fixture()
  let result = Ruleset::of_rules([
    MaxImageSize(1024),
    MaxWastedSize(1),
    MinEfficiency(0.3),
  ]).check(report, tree)
  assert_eq(result.results.length(), 3)
  assert_eq(result.passed_count(), 2)
  assert_eq(result.failed_count(), 1)
  assert_eq(exit_code_of(result), 1)
}

///|
/// 全过时退出码为 0。
async test "exit code when all pass" {
  let (report, tree) = @image_ci.covered_fixture()
  let result = Ruleset::of_rules([MaxImageSize(1024)]).check(report, tree)
  assert_eq(exit_code_of(result), 0)
  assert_eq(exit_code_of(result), exit_ok)
}

///|
/// 规则类型名与 JSON 里的 `type` 一致。
async test "rule type names match the dsl" {
  let (report, tree) = @image_ci.covered_fixture()
  let result = Ruleset::of_rules([
    MaxImageSize(1),
    MaxLayerSize(1),
    MaxWastedSize(1),
    MinEfficiency(1.0),
    DenyPaths(["/x"]),
    AllowPaths(["/x"]),
    MaxFileSize(1, None),
  ]).check(report, tree)
  let names = result.results.map(fn(item) { rule_type_name(item.rule) })
  assert_eq(names, [
    "maxImageSize", "maxLayerSize", "maxWastedSize", "minEfficiency", "denyPaths",
    "allowPaths", "maxFileSize",
  ])
}
