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
  /// 当前层号；`None` 表示还没进到「逐层下载」
  mut current : Int32?
  /// 这一层已下、这一层总量
  mut received : Int64
  mut total : Int64
  /// 整个镜像要下多少（`Plan` 给的），用来算整体进度
  mut plan_bytes : Int64
  /// 之前各层已完成的总量：整体进度 = done + 当前层已下
  mut done_bytes : Int64
  /// 最近一次刷出去的行（tty 上要能擦掉重画）
  mut last_width : Int32
  /// 还没写出去的那一行（`flush` 负责真正写 stderr）
  mut pending : String?
  /// 已经打过普通行、还没被清掉：下一次重画前要先换行
  mut pending_line : Bool
}

///|
pub fn PullReporter::new() -> PullReporter {
  PullReporter::with_interactive(interactive=stderr_is_a_terminal())
}

///|
/// `interactive` 由调用方决定：测试里要能固定成「非终端」，
/// 而真正的 tty 探测放在 `new()` 里（它要问操作系统）。
pub fn PullReporter::with_interactive(interactive~ : Bool) -> PullReporter {
  {
    interactive,
    current: None,
    received: 0L,
    total: 0L,
    plan_bytes: 0L,
    done_bytes: 0L,
    last_width: 0,
    pending: None,
    pending_line: false,
  }
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
    }
    None => ()
  }
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
      self.done_bytes = 0L
      self.line("\{layers} layers, \{human_bytes(bytes)} to download")
    }
    LayerStarted(index~, digest=_, bytes~) => {
      self.current = Some(index)
      self.received = 0L
      self.total = bytes
      // 层的起点就是这一行：`\r` 重画它，再往后就是同一行的百分比
      self.progress_line(0L, bytes)
    }
    LayerProgress(index~, received~, total~) => {
      // 事件可能来自另一层（并发拉取时），对不上就当成新的一层
      if self.current is None || self.current != Some(index) {
        self.current = Some(index)
        self.received = 0L
      }
      self.received = received
      if total > 0 {
        self.total = total
      }
      self.progress_line(received, self.total)
    }
    LayerDone(index~, bytes~) => {
      self.done_bytes = self.done_bytes + bytes
      self.current = None
      self.received = 0L
      // 收尾打一行「完成」，把 `\r` 那行定格，后面的日志才不会被吃掉
      self.line(
        "layer \{index + 1} done: \{human_bytes(bytes)} (total \{self.overall_percent()}%)",
      )
    }
    Packing(note~) => self.line(note)
    Writing(path~, bytes~) =>
      self.line("writing \{path} (\{human_bytes(bytes)})")
  }
}

///|
/// 当前这一层的进度（0-100）；没在下载就是 0。
pub fn PullReporter::layer_percent(self : PullReporter) -> Int32 {
  if self.total <= 0L {
    return 0
  }
  (self.received * 100L / self.total).to_int()
}

///|
/// 整体进度：已完成 + 当前层已下，除以 `Plan` 报的总量。
pub fn PullReporter::overall_percent(self : PullReporter) -> Int32 {
  if self.plan_bytes <= 0L {
    return 0
  }
  let loaded = self.done_bytes + self.received
  if loaded >= self.plan_bytes {
    return 100
  }
  let percent = loaded * 100L / self.plan_bytes
  percent.to_int()
}

///|
/// 画一行「第几层 已下/总量 百分比 速度」，用 `\r` 回到行首覆盖上一条。
fn PullReporter::progress_line(
  self : PullReporter,
  received : Int64,
  total : Int64,
) -> Unit {
  // 事件里的 index 是 0 起的层号，显示时 +1（与 `dive --layer N` 对得上）
  let layer = match self.current {
    Some(index) => index + 1
    None => 1
  }
  let percent = if total > 0L { (received * 100L / total).to_int() } else { 0 }
  let text = "layer \{layer}: \{human_bytes(received)} / \{human_bytes(total)} (\{percent}%) [overall \{self.overall_percent()}%]"
  // 比上一条短时必须用空格补满，否则残留字符会糊在行尾
  let width = self.last_width
  let padded = if text.length() < width {
    text + " ".repeat(width - text.length())
  } else {
    text
  }
  if self.interactive {
    // 靠 `\r` 回到行首覆盖自己，多一个 `\n` 就会刷屏
    self.pending = Some(padded)
  } else {
    // 管道里没法「原地刷新」：每格一行，下游按行处理也不会丢信息
    self.pending = None
    write_stderr("\{text}\n")
  }
  self.last_width = text.length()
  self.pending_line = true
}

///|
/// 打一行普通日志；如果上一条是 `\r` 进度行，先换行再写。
fn PullReporter::line(self : PullReporter, message : String) -> Unit {
  if self.pending_line {
    eprintln("")
    self.pending_line = false
  }
  self.last_width = 0
  self.pending = None
  eprintln(message)
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
