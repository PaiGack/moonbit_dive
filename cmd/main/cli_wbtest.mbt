///|
/// 解析一段 argv（不含程序名），返回选项。
fn parse_options(args : Array[String]) -> Options raise {
  let matches = cli().parse(argv=args) catch {
    err => fail("should parse: \{err}")
  }
  Options::from_matches(matches)
}

///|
async test "efficiency flag defaults to off and top to 10" {
  let options = parse_options(["demo.tar"])
  assert_false(options.efficiency)
  assert_eq(options.top, 10)
  assert_eq(options.layer, None)
}

///|
async test "efficiency and top are parsed" {
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
async test "top rejects non-numeric input" {
  // `non_negative_int_or_exit` 会 exit 2，这里只验正常路径不会被误判
  assert_eq(parse_non_negative_int("0"), Some(0))
  assert_eq(parse_non_negative_int("10"), Some(10))
  assert_eq(parse_non_negative_int("-1"), None)
  assert_eq(parse_non_negative_int("1e3"), None)
  assert_eq(parse_non_negative_int(""), None)
}

///|
/// `--from-image` / `--no-pull` / `--verbose` 默认关；给了要能认出来。
/// 「本地缺镜像就拉」是默认行为（对齐原版 dive），所以默认 `no_pull = false`。
async test "from-image and verbose flags are parsed" {
  let options = parse_options(["nginx:latest"])
  assert_false(options.from_image)
  assert_false(options.no_pull)
  assert_false(options.verbose)

  let options = parse_options(["nginx:latest", "--from-image", "--verbose"])
  assert_true(options.from_image)
  assert_true(options.verbose)
  // 这两个开关不该动到别的选项
  assert_eq(options.image, "nginx:latest")
  assert_eq(options.format, "text")
  assert_eq(options.layer, None)
  // 不给 `--no-pull` 就保持默认「缺了就拉」
  assert_false(options.no_pull)
}

///|
/// `--no-pull` 单独给（没有 `--from-image`）也解析得出来，但取归档时不生效：
/// 位置参数仍是文件，链路完全不碰 docker。
async test "no-pull is parsed but inert without from-image" {
  let options = parse_options(["demo.tar", "--no-pull"])
  assert_true(options.no_pull)
  assert_false(options.from_image)

  let options = parse_options(["nginx:latest", "--from-image", "--no-pull"])
  assert_true(options.no_pull)
  assert_true(options.from_image)
}

///|
/// 不给 `--from-image` 时，位置参数原样保留（当文件路径用）。
async test "image positional is kept as-is without from-image" {
  let options = parse_options(["./demo.tar", "--format", "json"])
  assert_eq(options.image, "./demo.tar")
  assert_false(options.from_image)
  assert_eq(options.format, "json")
}

///|
/// `--tui` 默认关；打开后不影响其它开关的语义。
async test "tui flag defaults to off and is independent" {
  let options = parse_options(["demo.tar"])
  assert_false(options.tui)
  let with_tui = parse_options(["demo.tar", "--tui"])
  assert_true(with_tui.tui)
  // 顺手开 `--tui` 不该改掉门禁/视图的开关
  assert_false(with_tui.efficiency)
  assert_eq(with_tui.layer, None)
  assert_eq(with_tui.format, "text")
}

///|
/// `--aggregate` 默认关；打开后不影响其它开关的语义（issue #69）。
async test "aggregate flag defaults to off and is independent" {
  let options = parse_options(["demo.tar"])
  assert_false(options.aggregate)
  let with_aggregate = parse_options(["demo.tar", "--aggregate", "--layer", "2"])
  assert_true(with_aggregate.aggregate)
  assert_eq(with_aggregate.layer, Some(2))
  // 顺手开 `--aggregate` 不该改掉门禁/视图的开关
  assert_false(with_aggregate.efficiency)
  assert_false(with_aggregate.tui)
  assert_eq(with_aggregate.format, "text")
}

///|
/// `--jobs` 默认 4（并发拉几层），给了就按给的算。
async test "jobs defaults to 4 and can be overridden" {
  let options = parse_options(["nginx:latest", "--from-registry"])
  assert_eq(options.jobs, 4)
  // 1 = 逐层串行：是一条要留着的退路
  let options = parse_options(["nginx:latest", "--from-registry", "--jobs", "1"])
  assert_eq(options.jobs, 1)
  // 给的数字不该顺手改掉别的选项
  assert_true(options.from_registry)
  assert_eq(options.image, "nginx:latest")
}
