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

///|
/// `--from-image` / `--pull` / `--verbose` 默认关；给了要能认出来。
test "from-image and verbose flags are parsed" {
  let options = parse_options(["nginx:latest"])
  assert_false(options.from_image)
  assert_false(options.pull)
  assert_false(options.verbose)

  let options = parse_options(["nginx:latest", "--from-image", "--verbose"])
  assert_true(options.from_image)
  assert_true(options.verbose)
  // 这两个开关不该动到别的选项
  assert_eq(options.image, "nginx:latest")
  assert_eq(options.format, "text")
  assert_eq(options.layer, None)
  // 不给 `--pull` 就不该顺手开启拉取
  assert_false(options.pull)
}

///|
/// `--pull` 单独给（没有 `--from-image`）也解析得出来，但取归档时不生效：
/// 位置参数仍是文件，链路完全不碰 docker。
test "pull is parsed but inert without from-image" {
  let options = parse_options(["demo.tar", "--pull"])
  assert_true(options.pull)
  assert_false(options.from_image)

  let options = parse_options(["nginx:latest", "--from-image", "--pull"])
  assert_true(options.pull)
  assert_true(options.from_image)
}

///|
/// 不给 `--from-image` 时，位置参数原样保留（当文件路径用）。
test "image positional is kept as-is without from-image" {
  let options = parse_options(["./demo.tar", "--format", "json"])
  assert_eq(options.image, "./demo.tar")
  assert_false(options.from_image)
  assert_eq(options.format, "json")
}
