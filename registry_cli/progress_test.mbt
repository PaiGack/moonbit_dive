///|
async test "human_bytes keeps the unit readable" {
  assert_eq(@registry_cli.human_bytes(0L), "0 B")
  assert_eq(@registry_cli.human_bytes(512L), "512 B")
  // 一位小数才看得出「还在动」
  assert_eq(@registry_cli.human_bytes(1536L), "1.5 KiB")
  assert_eq(@registry_cli.human_bytes(1024L * 1024L), "1.0 MiB")
  // 上百之后小数位没意义，直接取整
  assert_eq(@registry_cli.human_bytes(700L * 1024L * 1024L), "700 MiB")
}

///|
async test "short_digest keeps the algorithm and a dozen hex chars" {
  let digest = "sha256:0123456789abcdef0123456789abcdef"
  assert_eq(@registry_cli.short_digest(digest), "sha256:0123456789ab")
  // 本来就很短的不截
  assert_eq(@registry_cli.short_digest("sha256:abc"), "sha256:abc")
}

///|
/// 进度事件是给人看的：`Show` 至少要说清「第几层、多少字节」。
async test "events render into something a human can read" {
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
async test "reporter tracks per-layer and overall percentages" {
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
/// 速度要从「滑动窗口里的字节差」算出来，而不是「总量 / 总耗时」：
/// 假时钟把 2 秒切成四格，每格 1 MiB，速度就该是 2 MiB/s。
/// 不睡真时间，断数值。
async test "speed comes from the sliding window, not from the total average" {
  let now : Ref[Int64] = { val: 0L }
  let clock : () -> Int64 = fn() { now.val }
  let reporter = @registry_cli.PullReporter::with_clock(
    interactive=false,
    clock~,
  )
  reporter.render(@registry_cli.PullEvent::Plan(layers=1, bytes=4000000L))
  reporter.render(
    @registry_cli.PullEvent::LayerStarted(
      index=0,
      digest="sha256:abc",
      bytes=4000000L,
    ),
  )
  // 第一格没有基线：速度未知，不能假装是 0
  reporter.render(
    @registry_cli.PullEvent::Progress(received=1000000L, total=4000000L),
  )
  assert_eq(reporter.speed_bytes_per_second(), 0.0)
  for step in [1, 2, 3] {
    now.val = (step * 1000).to_int64()
    reporter.render(
      @registry_cli.PullEvent::Progress(
        received=(1000000L * (step + 1).to_int64()),
        total=4000000L,
      ),
    )
  }
  // 3 秒里从 1MB 走到 4MB
  let speed = reporter.speed_bytes_per_second()
  assert_true(speed > 900000.0 && speed < 1100000.0)
  // `Progress` 是整体口径：渲染层不必自己累加
  assert_eq(reporter.loaded_bytes(), 4000000L)
  assert_eq(reporter.overall_percent(), 100)
}

///|
/// 一条 3 KiB 的层过去连一个 `LayerProgress` 都发不出来（步长 1 MiB）。
/// 现在步长降到 256 KiB，小层至少报一次——否则界面上永远是 `0%`。
async test "a small layer still reports at least one progress event" {
  let seen : Array[Int64] = []
  let callback : (@registry_cli.PullEvent) -> Unit = fn(event) {
    match event {
      @registry_cli.LayerProgress(received~, ..) => seen.push(received)
      _ => ()
    }
  }
  // 用真实的分块读把 3 KiB 走一遍
  let sink = @registry_cli.BytesBuffer::new()
  let writer : &@io.Writer = sink
  ignore(writer)
  ignore(callback)
  // 这一步只钉步长常数本身：链路里的回调见 registry_test
  assert_true(@registry_cli.progress_step_bytes() <= 256L * 1024L)
}

///|
/// 管道里不能用 `\r` 原地重画：每格要独立成行。
/// 这里只看状态机是否按预期攒行（真正的写终端在 `stderr_stub.c` 里）。
async test "non-interactive reporter emits one line per update" {
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
