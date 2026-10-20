///|
test "human_bytes keeps the unit readable" {
  assert_eq(@registry_cli.human_bytes(0L), "0 B")
  assert_eq(@registry_cli.human_bytes(512L), "512 B")
  // 一位小数才看得出「还在动」
  assert_eq(@registry_cli.human_bytes(1536L), "1.5 KiB")
  assert_eq(@registry_cli.human_bytes(1024L * 1024L), "1.0 MiB")
  // 上百之后小数位没意义，直接取整
  assert_eq(@registry_cli.human_bytes(700L * 1024L * 1024L), "700 MiB")
}

///|
test "short_digest keeps the algorithm and a dozen hex chars" {
  let digest = "sha256:0123456789abcdef0123456789abcdef"
  assert_eq(@registry_cli.short_digest(digest), "sha256:0123456789ab")
  // 本来就很短的不截
  assert_eq(@registry_cli.short_digest("sha256:abc"), "sha256:abc")
}

///|
/// 进度事件是给人看的：`Show` 至少要说清「第几层、多少字节」。
test "events render into something a human can read" {
  let text = @registry_cli.PullEvent::LayerProgress(
    index=1,
    received=1024L * 1024L,
    total=2L * 1024L * 1024L,
  ).to_string()
  assert_true(text.contains("layer 2"))
  assert_true(text.contains("50%"))
}

///|
/// 渲染器要能把「第几层 / 百分比 / 整体进度」算对：
/// 事件流是唯一真相，测试直接喂事件、看它攒下的那一行。
test "reporter tracks per-layer and overall percentages" {
  let reporter = @registry_cli.PullReporter::new()
  reporter.render(@registry_cli.PullEvent::Plan(layers=2, bytes=200L))
  reporter.render(
    @registry_cli.PullEvent::LayerStarted(
      index=1,
      digest="sha256:abc",
      bytes=100L,
    ),
  )
  reporter.render(
    @registry_cli.PullEvent::LayerProgress(index=1, received=50L, total=100L),
  )
  // 第一层下了 50/100，整体就是 50/200
  assert_eq(reporter.overall_percent(), 25)
  assert_eq(reporter.layer_percent(), 50)
  // 一层收尾后再开下一层：整体进度累加已完成的部分
  reporter.render(@registry_cli.PullEvent::LayerDone(index=1, bytes=100L))
  reporter.render(
    @registry_cli.PullEvent::LayerStarted(
      index=2,
      digest="sha256:def",
      bytes=100L,
    ),
  )
  assert_eq(reporter.overall_percent(), 50)
  // 第二层下完就是 100%
  reporter.render(@registry_cli.PullEvent::LayerDone(index=2, bytes=100L))
  assert_eq(reporter.overall_percent(), 100)
}

///|
/// 管道里不能用 `\r` 原地重画：每格要独立成行。
/// 这里只看状态机是否按预期攒行（真正的写终端在 `stderr_stub.c` 里）。
test "non-interactive reporter emits one line per update" {
  let reporter = @registry_cli.PullReporter::with_interactive(interactive=false)
  reporter.render(@registry_cli.PullEvent::Plan(layers=1, bytes=100L))
  reporter.render(
    @registry_cli.PullEvent::LayerStarted(
      index=0,
      digest="sha256:abc",
      bytes=100L,
    ),
  )
  // 非交互模式不攒「半行」，所以 flush 无事可做
  assert_true(reporter.pending() is None)
  reporter.render(
    @registry_cli.PullEvent::LayerProgress(index=0, received=50L, total=100L),
  )
  assert_true(reporter.pending() is None)
}
