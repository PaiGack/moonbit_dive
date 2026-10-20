///|
/// 一层的进度状态。并发拉取时事件会交错，**每层各存一份**：
/// 只有一个 `current` 指针的写法会让第 3 层的事件把第 7 层的字节数改掉。
struct LayerState {
  /// 这一层已下、这一层总量
  mut received : Int64
  mut total : Int64
}

///|
fn LayerState::new(total : Int64) -> LayerState {
  { received: 0L, total, }
}

///|
/// 命令行上的进度渲染器：把 `PullEvent` 变成人能看到的一行。
///
/// 单独放一层是为了让「拉取逻辑」与「怎么显示」各管各的：
/// 前者只报事实（`PullEvent`），后者决定要不要 `\r`、要不要百分比。
/// 将来的 TUI 想复用同一个事件流，换掉这一层就够。
///
/// 用法：
///
/// ```
/// let reporter = PullReporter::new()
/// let options = PullOptions::new(on_progress=Some(reporter.handle()))
/// ```
pub struct PullReporter {
  /// 终端上才用 `\r` 重画；管道 / 重定向里每格换一行（否则会糊成一条长龙）
  interactive : Bool
  /// 每层一份进度（层号 -> 状态）。并发是**事实**，串行只是它的特例
  layers : Map[Int32, LayerState]
  /// 最近一次收到的 `LayerStarted` 的层号：单层串行时它就是「当前层」，
  /// 也是进度行上「layer N/M」里的 N
  mut current : Int32?
  /// 整个镜像要下多少（`Plan` 给的）
  mut plan_bytes : Int64
  /// 一共几层（`Plan` 给的）；只在收尾那一行用得上
  mut plan_layers : Int32
  /// 拉取侧报的全局已拿字节（`Progress`），`None` 时退回自己累加
  mut reported_bytes : Int64?
  /// 已完成层之和 + 各层在途字节；只在没有 `Progress` 时兜底
  mut done_bytes : Int64
  /// 最近一次刷出去的行（tty 上要能擦掉重画）
  mut last_width : Int32
  /// 还没写出去的那一行（`flush` 负责真正写 stderr）
  mut pending : String?
  /// 已经打过普通行、还没被清掉：下一次重画前要先换行
  mut pending_line : Bool
  /// 时间源（毫秒）。注入假时钟就不用为了测速度去睡真时间
  clock : () -> Int64
  /// 速度窗口里的采样：(时刻, 全局已拿字节)
  samples : Array[(Int64, Int64)]
  /// 上一次更新速度的时刻；`None` 表示还没有基线，速度显示 `--`
  mut speed_mark : Int64?
  /// 最近算出来的速度（字节/秒）
  mut speed : Double
  /// 上一次真正往终端写的时刻（限频用；`None` = 还没写过）
  mut painted_at : Int64?
}

///|
/// 速度窗口取多长。1.5 秒足够抹平 CDN 的抖动，又不至于把「刚慢下来」藏太久。
let speed_window_millis : Int64 = 1500

///|
/// 同一行两次实际写入的最小间隔。每秒 5 次是人眼的上限；
/// 再密就只是往终端刷 `\r`，反而吃 CPU（大层上原本是每 1 MiB 一次）。
let min_repaint_millis : Int64 = 200

///|
pub fn PullReporter::new() -> PullReporter {
  PullReporter::with_interactive(interactive=stderr_is_a_terminal())
}

///|
/// `interactive` 由调用方决定：测试里要能固定成「非终端」，
/// 而真正的 tty 探测放在 `new()` 里（它要问操作系统）。
pub fn PullReporter::with_interactive(interactive~ : Bool) -> PullReporter {
  PullReporter::with_clock(interactive~, clock=monotonic_millis)
}

///|
/// 注入时间源。测试用它换掉真实单调时钟——速度是「字节差 / 时间差」，
/// 断数值不该靠 `sleep`，那既慢又不稳。
pub fn PullReporter::with_clock(
  interactive~ : Bool,
  clock~ : () -> Int64,
) -> PullReporter {
  {
    interactive,
    layers: Map([]),
    current: None,
    plan_bytes: 0L,
    plan_layers: 0,
    reported_bytes: None,
    done_bytes: 0L,
    last_width: 0,
    pending: None,
    pending_line: false,
    clock,
    samples: [],
    speed_mark: None,
    speed: 0.0,
    painted_at: None,
  }
}

///|
/// 单调时钟（毫秒）。刻意不用墙钟：NTP 往回跳一下就能算出负速度。
fn monotonic_millis() -> Int64 {
  @async.now()
}

///|
/// 拿一个能直接塞进 `PullOptions` 的回调。
///
/// 回调是同步的（拉取逻辑不该等终端），所以进度行只**攒着**，
/// 由 `flush` 在合适的时机真正写出去；不调 `flush` 也不会丢，
/// 只是最后一格没画出来。
pub fn PullReporter::handle(self : PullReporter) -> (PullEvent) -> Unit {
  fn(event) { self.render(event) }
}

///|
/// 把攒下的进度行写到 stderr。
///
/// 拉取是 async、回调是同步，中间没有可插入 await 的缝；所以回调只更新状态，
/// 真正的写由持有者在这个 async 上下文里做。
pub fn PullReporter::flush(self : PullReporter) -> Unit noraise {
  match self.pending {
    Some(text) => {
      self.pending = None
      // 终端写不进去不影响拉取本身：分析结果走 stdout，进度只是提示
      write_stderr("\r\{text}")
      self.painted_at = Some(self.now())
    }
    None => ()
  }
}

///|
/// 当前时刻（毫秒）。
fn PullReporter::now(self : PullReporter) -> Int64 {
  (self.clock)()
}

///|
/// stderr 是不是终端。探测失败按「不是」处理：非交互时多打几行，
/// 总比往文件里塞一堆 `\r` 好。
fn stderr_is_a_terminal() -> Bool noraise {
  stderr_is_tty_ffi() != 0
}

///|
/// `stderr_stub.c` 里的 `isatty(fileno(stderr))`。
extern "C" fn stderr_is_tty_ffi() -> Int32 = "dive_stderr_is_tty"

///|
/// 往 stderr 写一段（失败就当没写）。
fn write_stderr(text : String) -> Unit noraise {
  write_to_stderr(text)
}

///|
/// 处理一个事件并画一行。
///
/// 进度行写 stderr：报告可能走 stdout 被管道 / 重定向消费，
/// 混进去的 `\r` 会让下游拿到一堆控制字符（也是为什么进度默认不该进报告）。
pub fn PullReporter::render(self : PullReporter, event : PullEvent) -> Unit {
  match event {
    Started(reference~) => self.line("pulling \{reference}")
    Plan(layers~, bytes~) => {
      self.plan_bytes = bytes
      self.plan_layers = layers
      self.done_bytes = 0L
      self.reported_bytes = None
      self.layers.clear()
      self.current = None
      self.reset_speed()
      self.line("\{layers} layers, \{human_bytes(bytes)} to download")
    }
    LayerStarted(index~, digest=_, bytes~) => {
      self.current = Some(index)
      self.layers.set(index, LayerState::new(bytes))
      // 层的起点就是这一行：`\r` 重画它，再往后就是同一行的百分比
      self.progress_line(index)
    }
    LayerProgress(index~, received~, total~) => {
      let state = match self.layers.get(index) {
        Some(state) => state
        None => {
          let state = LayerState::new(total)
          self.layers.set(index, state)
          state
        }
      }
      state.received = received
      if total > 0L {
        state.total = total
      }
      self.current = Some(index)
      self.progress_line(index)
    }
    LayerDone(index~, bytes~) => {
      self.done_bytes = self.done_bytes + bytes
      self.layers.remove(index)
      if self.current == Some(index) {
        self.current = None
      }
      // 收尾打一行「完成」，把 `\r` 那行定格，后面的日志才不会被吃掉。
      // 并发之下这一行会乱序出现——那是事实，不是 bug；整体行才是进度条。
      self.line(
        "layer \{index + 1} done: \{human_bytes(bytes)} (total \{self.overall_percent()}%)",
      )
    }
    Progress(received~, total~) => {
      self.reported_bytes = Some(received)
      if total > 0L {
        self.plan_bytes = total
      }
      self.update_speed(received)
      match self.current {
        Some(index) => self.progress_line(index)
        None => self.overall_line()
      }
    }
    Packing(note~) => self.line(note)
    Writing(path~, bytes~) =>
      self.line("writing \{path} (\{human_bytes(bytes)})")
  }
}

///|
/// 收尾：把所有层的最后已知状态与平均速度说清楚。
///
/// 失败时最要紧的信息是**下到哪一步断的**。半行进度后面直接接错误信息会糊成
/// 一团，所以先换行，再交代「断在第几层、跑了多久、平均多快」。
pub fn PullReporter::finish(self : PullReporter, failed~ : Bool) -> Unit noraise {
  if self.pending_line {
    write_stderr("\n")
    self.pending_line = false
  }
  self.pending = None
  let loaded = self.loaded_bytes()
  let elapsed = self.elapsed_millis()
  let rate = if elapsed > 0 {
    loaded.to_double() * 1000.0 / elapsed.to_double()
  } else {
    0.0
  }
  let at_layer = match self.current {
    Some(index) => " at layer \{index + 1}/\{self.plan_layers}"
    None => ""
  }
  let text = if failed {
    "failed\{at_layer} after \{seconds_text(elapsed)} (\{human_rate(rate)})"
  } else {
    "downloaded \{human_bytes(loaded)}\{at_layer} in \{seconds_text(elapsed)} (\{human_rate(rate)})"
  }
  write_stderr("\{text}\n")
}

///|
fn seconds_text(millis : Int64) -> String {
  if millis <= 0 {
    return "0.0s"
  }
  let tenths = millis / 100
  "\{tenths / 10}.\{tenths % 10}s"
}

///|
/// 已经拉了多久：从第一份速度基线（或者第一次碰到数据）算起。
fn PullReporter::elapsed_millis(self : PullReporter) -> Int64 {
  match self.samples {
    [] => 0L
    samples => self.now() - samples[0].0
  }
}

///|
/// 当前这一层的进度（0-100）；没在下载就是 0。
pub fn PullReporter::layer_percent(self : PullReporter) -> Int32 {
  let index = match self.current {
    Some(index) => index
    None => return 0
  }
  let state = match self.layers.get(index) {
    Some(state) => state
    None => return 0
  }
  if state.total <= 0L {
    return 0
  }
  (state.received * 100L / state.total).to_int()
}

///|
/// 整体已经拿到的字节：拉取侧报的 `Progress` 优先，没有就自己加。
pub fn PullReporter::loaded_bytes(self : PullReporter) -> Int64 {
  match self.reported_bytes {
    Some(bytes) => bytes
    None => {
      let mut inflight = 0L
      for _, state in self.layers {
        inflight = inflight + state.received
      }
      self.done_bytes + inflight
    }
  }
}

///|
/// 整体进度：已拿字节除以 `Plan` 报的总量。
pub fn PullReporter::overall_percent(self : PullReporter) -> Int32 {
  if self.plan_bytes <= 0L {
    return 0
  }
  let loaded = self.loaded_bytes()
  if loaded >= self.plan_bytes {
    return 100
  }
  let percent = loaded * 100L / self.plan_bytes
  percent.to_int()
}

///|
/// 最近一次算出来的速度（字节/秒）。没有基线时是 0，显示成 `--`。
pub fn PullReporter::speed_bytes_per_second(self : PullReporter) -> Double {
  self.speed
}

///|
/// 把当前已拿字节喂进滑动窗口，算出速度。
///
/// 用「最近 1.5 秒的字节差 / 时间差」而不是「总量 / 总耗时」：
/// 后者在 CDN 抖一下之后会长时间停在那个骗人的平均值上，
/// 而用户想知道的恰恰是**现在**快不快。
fn PullReporter::update_speed(self : PullReporter, received : Int64) -> Unit {
  let now = self.now()
  self.samples.push((now, received))
  while self.samples.length() > 1 && now - self.samples[0].0 > speed_window_millis {
    ignore(self.samples.remove(0))
  }
  match self.samples[0] {
    (first_at, first_bytes) =>
      if now > first_at && self.speed_mark is Some(_) {
        self.speed = (received - first_bytes).to_double() *
          1000.0 /
          (now - first_at).to_double()
      }
  }
  self.speed_mark = Some(now)
}

///|
fn PullReporter::reset_speed(self : PullReporter) -> Unit {
  self.samples.clear()
  self.speed_mark = None
  self.speed = 0.0
  self.painted_at = None
}

///|
/// 画一行「第几层 已下/总量 百分比 速度」，用 `\r` 回到行首覆盖上一条。
fn PullReporter::progress_line(self : PullReporter, index : Int32) -> Unit {
  // 事件里的 index 是 0 起的层号，显示时 +1（与 `dive --layer N` 对得上）
  let layer = index + 1
  let state = match self.layers.get(index) {
    Some(state) => state
    None => return
  }
  let percent = if state.total > 0L {
    (state.received * 100L / state.total).to_int()
  } else {
    0
  }
  let speed = if self.speed_mark is Some(_) && self.speed > 0.0 {
    human_rate(self.speed)
  } else {
    "--"
  }
  let text = "layer \{layer}: \{human_bytes(state.received)} / \{human_bytes(state.total)} (\{percent}%)  \{speed}  [overall \{self.overall_percent()}%]"
  self.paint(text)
}

///|
/// 没有在下的层时画整体那一行（`Progress` 事件可能要等第一个字节）。
fn PullReporter::overall_line(self : PullReporter) -> Unit {
  let speed = if self.speed_mark is Some(_) && self.speed > 0.0 {
    human_rate(self.speed)
  } else {
    "--"
  }
  let text = "overall \{human_bytes(self.loaded_bytes())} / \{human_bytes(self.plan_bytes)} (\{self.overall_percent()}%)  \{speed}"
  self.paint(text)
}

///|
/// 真正把一行送出去，顺手做限频。
///
/// 拉取侧每 256 KiB 就会报一次，大层上那是每秒上千次；而人眼每秒 5 次就到顶。
/// 所以这里挡一道：离上次写入不到 200ms 就先攒着，攒着的终究会被下一次
/// `render` / `flush` 或者心跳写出去——最后一格由调用方的 `flush` 兜底。
fn PullReporter::paint(self : PullReporter, text : String) -> Unit {
  if self.interactive {
    let now = self.now()
    match self.painted_at {
      Some(at) =>
        if now - at < min_repaint_millis {
          // 比上一条短时必须用空格补满，否则残留字符会糊在行尾
          self.pending = Some(self.padded(text))
          self.pending_line = true
          return
        }
      None => ()
    }
  }
  self.emit(text)
}

///|
fn PullReporter::padded(self : PullReporter, text : String) -> String {
  let width = self.last_width
  if text.length() < width {
    text + " ".repeat(width - text.length())
  } else {
    text
  }
}

///|
fn PullReporter::emit(self : PullReporter, text : String) -> Unit {
  let padded = self.padded(text)
  if self.interactive {
    // 靠 `\r` 回到行首覆盖自己，多一个 `\n` 就会刷屏
    self.pending = Some(padded)
    write_stderr("\r\{padded}")
    self.painted_at = Some(self.now())
  } else {
    // 管道里没法「原地刷新」：每格一行，下游按行处理也不会丢信息
    self.pending = None
    self.painted_at = Some(self.now())
    write_stderr("\{text}\n")
  }
  self.last_width = text.length()
  self.pending_line = true
}

///|
/// 打一行普通日志；如果上一条是 `\r` 进度行，先换行再写。
fn PullReporter::line(self : PullReporter, message : String) -> Unit {
  if self.pending_line {
    write_stderr("\n")
    self.pending_line = false
  }
  self.last_width = 0
  self.pending = None
  write_stderr("\{message}\n")
}

///|
/// `stderr_stub.c` 的薄封装：写多少算多少，失败不管。
#borrow(buf)
extern "C" fn write_stderr_ffi(buf : Bytes, len : Int32) -> Int32 = "dive_write_stderr"

///|
fn write_to_stderr(text : String) -> Unit noraise {
  let bytes = @encoding.encode(UTF8, text)
  ignore(write_stderr_ffi(bytes, bytes.length()))
}

///|
/// 测试用的口子：看看现在攒着哪半行（正常调用方不该关心）。
pub fn PullReporter::pending(self : PullReporter) -> String? {
  self.pending
}
