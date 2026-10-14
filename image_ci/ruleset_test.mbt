///|
/// 载入一份合法规则集，检查 id 与种类。
test "parse rules json" {
  let ruleset = Ruleset::parse(
    (
      #|{
      #|  "rules": [
      #|    { "type": "maxImageSize", "maxBytes": 1048576 },
      #|    { "id": "score-floor", "type": "minEfficiency", "score": 0.5 },
      #|    { "type": "denyPaths", "patterns": ["/app/node_modules/**"] }
      #|  ]
      #|}
    ),
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(ruleset.rules.length(), 3)
  assert_eq(ruleset.rules[0].id, "rule-1")
  assert_eq(ruleset.rules[1].id, "score-floor")
  assert_true(ruleset.rules[0].kind is MaxImageSize(_))
  assert_true(ruleset.rules[1].kind is MinEfficiency(_))
  assert_true(ruleset.rules[2].kind is DenyPaths(_))
  assert_eq(ruleset.source, "<inline>")
}

///|
/// 顶层 `ids` 数组可以批量命名。
test "top level ids rename rules" {
  let inline =
    #|{ "ids": ["a", "b"], "rules": [{ "type": "maxImageSize", "maxBytes": 1 }, { "type": "maxWastedSize", "maxBytes": 2 }] }
  let ruleset = Ruleset::parse(inline) catch { err => fail(err.to_string()) }
  assert_eq(ruleset.rules[0].id, "a")
  assert_eq(ruleset.rules[1].id, "b")
}

///|
/// 六类规则都能从 JSON 加载。
test "all six rule types load" {
  let ruleset = Ruleset::parse(
    (
      #|{
      #|  "rules": [
      #|    { "type": "maxImageSize", "maxBytes": 1024 },
      #|    { "type": "maxLayerSize", "maxBytes": 512 },
      #|    { "type": "maxWastedSize", "maxBytes": 256 },
      #|    { "type": "minEfficiency", "score": 0.75 },
      #|    { "type": "denyPaths", "patterns": ["/node_modules/**"] },
      #|    { "type": "allowPaths", "patterns": ["/app/**"] },
      #|    { "type": "maxFileSize", "maxBytes": 100, "scope": { "path": "/usr/**", "recursive": false } }
      #|  ]
      #|}
    ),
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(ruleset.rules.length(), 7)
}

///|
/// 规则非法：解析失败、空规则集、未知类型、越界数值。
test "config errors are distinguished" {
  let cases : Array[(String, String)] = [
    ("not json", "{oops"),
    ("not an object", "[1, 2]"),
    ("missing rules", "{}"),
    ("empty rules", "{\"rules\": []}"),
    ("rule not object", "{\"rules\": [1]}"),
    ("unknown type", "{\"rules\": [{\"type\": \"nope\"}]}"),
    (
      "bad number", "{\"rules\": [{\"type\": \"maxImageSize\", \"maxBytes\": \"big\"}]}",
    ),
    (
      "out of range", "{\"rules\": [{\"type\": \"maxImageSize\", \"maxBytes\": -1}]}",
    ),
    (
      "bad efficiency", "{\"rules\": [{\"type\": \"minEfficiency\", \"score\": 2.0}]}",
    ),
    (
      "empty patterns", "{\"rules\": [{\"type\": \"denyPaths\", \"patterns\": []}]}",
    ),
    (
      "bad scope", "{\"rules\": [{\"type\": \"maxFileSize\", \"maxBytes\": 1, \"scope\": {}}]}",
    ),
  ]
  for item in cases {
    let name = item.0
    let text = item.1
    let failed = match parse_as_result(text) {
      Ok(_) => false
      Err(_) => true
    }
    if !failed {
      fail("\{name} should have failed")
    }
  }
}

///|
/// 把 `raise` 风格的解析包成 `Result`，方便测试里判分支。
fn parse_as_result(text : String) -> Result[Ruleset, ConfigError] {
  let ruleset = Ruleset::parse(text) catch { err => return Err(err) }
  Ok(ruleset)
}
