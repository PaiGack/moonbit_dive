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
/// `--no-pull` / `--verbose` 默认关；给了要能认出来。
/// 「本地缺镜像就拉」是默认行为（对齐原版 dive），所以默认 `no_pull = false`。
async test "no-pull and verbose flags are parsed" {
  let options = parse_options(["nginx:latest"])
  assert_false(options.no_pull)
  assert_false(options.verbose)
  // 没有「这像不像镜像名」的开关了：位置参数怎么解释由它自己的形态决定
  assert_eq(kind_of_input("nginx:latest"), Reference)

  let options = parse_options(["nginx:latest", "--verbose", "--no-pull"])
  assert_true(options.verbose)
  assert_true(options.no_pull)
  // 这两个开关不该动到别的选项
  assert_eq(options.image, "nginx:latest")
  assert_eq(options.format, "text")
  assert_eq(options.layer, None)
}

///|
/// `--no-pull` 现在**总是**有意义：它拦的是「出网」，不是「这个开关生效不生效」。
/// 位置参数是本地文件时它照样能解析，只是那一路本来就不联网。
async test "no-pull is parsed for either kind of input" {
  let options = parse_options(["demo.tar", "--no-pull"])
  assert_true(options.no_pull)
  assert_eq(kind_of_input("demo.tar"), Reference)

  let options = parse_options(["nginx:latest", "--no-pull"])
  assert_true(options.no_pull)
}

///|
/// 位置参数**原样保留**：解释它的是 `kind_of_input`，不是解析阶段。
async test "the image positional is kept as-is" {
  let options = parse_options(["./demo.tar", "--format", "json"])
  assert_eq(options.image, "./demo.tar")
  assert_eq(options.format, "json")
  let options = parse_options(["nginx:latest"])
  assert_eq(options.image, "nginx:latest")
}

///|
/// 三档判定（issue #124）：`-` 是 stdin，存在的路径是本地输入，其余当镜像引用。
async test "the positional is classified into stdin, local path or reference" {
  assert_eq(kind_of_input("-"), Stdin)
  assert_true(is_local_input("-"))
  // 仓库里一定存在的东西：拿它当「路径存在」
  assert_eq(kind_of_input("moon.mod"), LocalPath)
  assert_true(is_local_input("moon.mod"))
  assert_eq(kind_of_input("cmd"), LocalPath)
  // 不存在的路径不会退化成「本地文件」，而是被当成镜像名——
  // 这正是「文件名打错」与「镜像名」共用一条入口时能给出的最好答案
  assert_eq(kind_of_input("/definitely/not/here.tar"), Reference)
  assert_false(is_local_input("/definitely/not/here.tar"))
  assert_eq(kind_of_input("nginx:latest"), Reference)
}

///|
/// `--no-tui` 默认关——也就是**默认开界面**（issue #128 的方案 B）。
///
/// 这个默认只影响 native 那条出口：能不能真开得起来另由 `refusal_of_tui`
/// 现场判（tty / stdin 是 tar 流）。`--no-tui` 是「我就是要文本」，
/// 给了它就不必再问终端。
async test "the browser defaults to on and --no-tui turns it off" {
  let options = parse_options(["demo.tar"])
  assert_false(options.no_tui)
  assert_true(options.interactive())
  let text_only = parse_options(["demo.tar", "--no-tui"])
  assert_true(text_only.no_tui)
  assert_false(text_only.interactive())
  // 顺手加 `--no-tui` 不该改掉门禁/视图的开关
  assert_false(text_only.efficiency)
  assert_eq(text_only.layer, None)
  assert_eq(text_only.format, "text")
}

///|
/// 老的 `--tui` 没了：默认就是界面，再多一个「打开」的开关只会让
/// `--tui --no-tui` 这种自相矛盾有地方藏。argparse 该直接报错。
async test "the old --tui flag is gone" {
  let rejected : Bool = try {
    cli().parse(argv=["demo.tar", "--tui"]) |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
/// `--save` 与界面互斥：真会开界面（要它 + 终端够格）时是 exit 2 的参数错，
/// 不能让 `--save` 悄悄吃掉界面，也不能让界面悄悄吃掉 `--save`。
async test "save and the browser are mutually exclusive" {
  let save_only = parse_options([
    "nginx:latest", "--save", "-o", "x.tar", "--no-tui",
  ])
  assert_true(save_only.save)
  assert_false(save_only.interactive())
  assert_false(browser_would_open(save_only))
  // 「要不要界面」只看这两个开关，与别的一概无关
  let clash = parse_options(["nginx:latest", "--save", "-o", "x.tar"])
  assert_true(clash.save && clash.interactive())
}

///|
/// 「要不要」与「会不会」是两问：`--save` 只在**真的会进界面**时才冲突。
///
/// `dive img --save -o x.tar > log` 在管道 / CI 里没有终端，界面本来就开不成，
/// 走的是文本出口——`--save` 不跟任何东西抢，不该被当成参数错。
/// 反过来 `dive - --save -o x.tar` 的 stdin 是 tar 流，同理。
async test "save only clashes when the browser would actually open" {
  for
    args in [
      ["nginx:latest", "--save", "-o", "x.tar"],
      ["-", "--save", "-o", "x.tar"],
    ] {
    let options = parse_options(args)
    assert_true(options.save)
    assert_true(options.interactive())
    // 这条与测试跑在不在终端里无关：`-` 在问 tty 之前就被挡下了
    if args[0] == "-" {
      assert_false(browser_would_open(options))
    }
  }
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
  assert_false(with_aggregate.no_tui)
  assert_eq(with_aggregate.format, "text")
}

///|
/// `--jobs` 默认 4（并发拉几层），给了就按给的算。
async test "jobs defaults to 4 and can be overridden" {
  let options = parse_options(["nginx:latest"])
  assert_eq(options.jobs, 4)
  // 1 = 逐层串行：是一条要留着的退路
  let options = parse_options(["nginx:latest", "--jobs", "1"])
  assert_eq(options.jobs, 1)
  // 给的数字不该顺手改掉别的选项
  assert_false(options.save)
  assert_eq(options.image, "nginx:latest")
}
