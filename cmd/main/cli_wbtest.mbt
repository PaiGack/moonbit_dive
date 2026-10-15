///|
/// 解析一段 argv（不含程序名），返回选项。
fn parse_options(args : Array[String]) -> Options raise {
  let matches = cli().parse(argv=args) catch {
    err => fail("should parse: \{err}")
  }
  Options::from_matches(matches)
}

///|
test "efficiency flag defaults to off and top to 10" {
  let options = parse_options(["demo.tar"])
  assert_false(options.efficiency)
  assert_eq(options.top, 10)
  assert_eq(options.layer, None)
}

///|
test "efficiency and top are parsed" {
  let options = parse_options([
    "demo.tar", "--efficiency", "--top", "20", "--path", "/app",
  ])
  assert_true(options.efficiency)
  assert_eq(options.top, 20)
  assert_eq(options.path, Some("/app"))
  // 三个开关各管各的，`--efficiency` 不该顺手改掉 `--layer` 的语义
  assert_eq(options.layer, None)
}

///|
test "top rejects non-numeric input" {
  // `non_negative_int_or_exit` 会 exit 2，这里只验正常路径不会被误判
  assert_eq(parse_non_negative_int("0"), Some(0))
  assert_eq(parse_non_negative_int("10"), Some(10))
  assert_eq(parse_non_negative_int("-1"), None)
  assert_eq(parse_non_negative_int("1e3"), None)
  assert_eq(parse_non_negative_int(""), None)
}
