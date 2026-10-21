///|
/// 界面出口的接线：命令行开关 → 起始态（issue #128 第二节）。
///
/// 这里只验「映射对不对」，真开界面要终端、要人在前面按 `q`，不进单测。
/// 每个开关都得有个落点：`--layer` 起始层、`--aggregate` 起始档位、
/// `--path` 光标落点、`--efficiency` 详情面板聚焦。
async test "cli flags map onto the browser start config" {
  let options = parse_options([
    "demo.tar", "--layer", "1", "--aggregate", "--path", "/app", "--efficiency",
  ])
  let notices : Array[String] = []
  let start = start_config_of(options, 3, notices)
  assert_eq(start.layer, 1)
  assert_eq(start.compare_mode, @tui.CompareMode::Aggregate)
  assert_eq(start.path, Some("/app"))
  assert_eq(start.focus, @tui.Focus::Detail)
  assert_true(notices.is_empty())
}

///|
/// 不给 `--layer` 就看最后一层——与文本出口的缺省同口径。
/// 给了但越界不拦路：夹回最后一层，并在 stderr 留一句。
async test "the browser opens the last layer by default and clamps a bad one" {
  let options = parse_options(["demo.tar"])
  let start = start_config_of(options, 4, [])
  assert_eq(start.layer, 3)
  assert_eq(start.compare_mode, @tui.CompareMode::Single)
  assert_eq(start.path, None)
  assert_eq(start.focus, @tui.Focus::Tree)
  let only = parse_options(["demo.tar"])
  let notices : Array[String] = []
  // 单层镜像：缺省层号是下标 0，不该被当成越界
  assert_eq(start_config_of(only, 1, notices).layer, 0)
  assert_true(notices.is_empty())
  let bad = parse_options(["demo.tar", "--layer", "9"])
  let notices : Array[String] = []
  assert_eq(start_config_of(bad, 4, notices).layer, 9)
  assert_eq(notices.length(), 1)
}

///|
/// `--save` 与界面互斥（第一条硬原则的反面：不静默让谁赢）。
///
/// 「互斥」判的是**会不会真开界面**：没给 `--no-tui` 也不算冲突，
/// 除非终端够格。所以这里只断言两问本身，终端那一半交给
/// `refusal_of_tui`——它才是不依赖环境的那个判据。
async test "save without --no-tui is a config error, not a silent choice" {
  let save = parse_options(["nginx:latest", "--save", "-o", "x.tar"])
  assert_true(save.save && save.interactive())
  let save_text = parse_options([
    "nginx:latest", "--save", "-o", "x.tar", "--no-tui",
  ])
  assert_false(save_text.save && save_text.interactive())
  assert_false(browser_would_open(save_text))
}

///|
/// 能不能开界面：`-`（stdin 是 tar）一票否决——界面会把 tar 流吃掉。
///
/// 这一档在问 tty 之前就返回，所以断言与环境无关：哪怕测试跑在真终端里也一样。
async test "an image from stdin never opens the browser" {
  let options = parse_options(["-"])
  let refusal = refusal_of_tui(options)
  assert_true(refusal is Some(_))
  let message = refusal.unwrap()
  assert_true(message.contains("stdin"))
  // 给了 `--no-tui` 就该走文本，闭嘴不提示
  assert_false(parse_options(["-", "--no-tui"]).interactive())
}
