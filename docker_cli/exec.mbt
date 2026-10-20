///|
/// 跑一个子进程并收集 stdout / stderr。
///
/// 走 `read_from_process` 而不是 `collect_output`：save 出来的归档动辄几百 MB，
/// 不能让运行时把它整段拼成 `String` 再转回 `Bytes`。
/// 这里的返回值仍全量驻留内存，落盘版本留给后续。
///
/// `timeout_ms` 是**空闲超时**，不是整次调用的总时长：只要子进程还在吐字节，
/// 计时就一直重置；只有「连续这么久一个字节都没有」才判死。见 `watch_idle`。
pub async fn run_cli(
  program : String,
  args : Array[String],
  timeout_ms : Int32,
) -> (Int32, Bytes, Bytes) raise DockerCliError {
  let (code, stdout, stderr, _) = run_capture(
    program,
    args,
    timeout_ms,
    clock=IdleClock::new(),
  )
  (code, stdout, stderr)
}

///|
/// 一次调用的收尾信息：退出码、两个流，以及「最后一次读到数据」的时刻。
///
/// 时刻要带出来，是因为超时文案得说清楚**是在等哪一步时**卡住的：
/// 拉取 30 秒没新字节，和从头到尾 30 秒没新字节，是完全两回事。
pub(all) struct CliRun {
  code : Int32
  /// 执行了多久（含被取消的那些），毫秒
  elapsed_ms : Int32
  /// 离上一次读到数据过去了多久，毫秒；一个字节都没读到就是整段耗时
  idle_ms : Int32
} derive(Eq, Debug)

///|
pub extend CliRun with Eq::{equal, not_equal}

///|
pub extend CliRun with @debug.Debug::{to_repr}

///|
/// stdout 的去向：收进内存，或者边读边写进某个 writer。
///
/// 用枚举而不是 `&@io.Writer?`：`&T?` 会被解析成 `&(T?)`，
/// 可选参数传下来就成了「引用一个可空的 writer」，trait 方法全用不了。
/// 落盘那条路要的正是「边读边写」，把这两件事写成显式的两个分支反而更直白。
pub(all) enum OutputSink {
  /// 收进返回值
  Memory
  /// 边读边写，内存里不留整段归档
  Stream(&@io.Writer)
}

///|
/// 跑一个子进程，把 stdout 写进 `sink`（`None` 表示收进内存）。
///
/// `sink` 走 `&@io.Writer` 而不是自己造一个回调类型：落盘那条路要的就是
/// 「边读边写文件」，而 `@fs` 的文件句柄本来就满足这个 trait。
///
/// 超时看的是**空闲**而不是总时长：`docker pull python:3.12` 这种几十秒的
/// 正常操作，进度行一直在刷，凭什么按 30 秒判死？反过来，
/// `docker pull` 卡在一个连不上的 registry 上时是真的一句话都没有，
/// 那才是超时该管的事。issue #94 里 `pulling docker.cnb.cool/...` 之后
/// 一行没出就被判超时，就是被这条「总时长 = 超时」的规则误伤的。
async fn run_capture(
  program : String,
  args : Array[String],
  timeout_ms : Int32,
  sink~ : OutputSink = Memory,
  clock~ : IdleClock,
) -> (Int32, Bytes, Bytes, CliRun) raise DockerCliError {
  let result = with_timeout(program, timeout_ms, clock, () => {
    run_once(program, args, clock, sink~)
  })
  let (code, out, err) = result
  (code, out, err, clock.report())
}

///|
/// 空闲计时器：`touch` 一次就把「最后活动时刻」推到当下。
///
/// 读流的任务和 `wait` 的任务各跑各的，共享这一个对象；
/// 外面那个**空闲**监工据此决定要不要收网。
pub(all) struct IdleClock {
  started : Int64
  mut last : Int64
}

///|
pub fn IdleClock::new() -> IdleClock {
  let now = @async.now()
  { started: now, last: now, }
}

///|
/// 有数据动了，重置计时。
///
/// `last` 用 `Int64` 而不是 `Int32`：`now()` 是单调时钟的原值，
/// 截成 32 位会在跑了很久的程序里绕回来，算出的间隔变成负数。
pub fn IdleClock::touch(self : IdleClock) -> Unit {
  self.last = @async.now()
}

///|
/// 收尾时把「总耗时 + 空闲耗时」算成一句可读的东西。
///
/// 两个数分开报，是因为它们的含义完全不同：
/// - `idle ≈ 总耗时` → 从头到尾没有输出，超时名正言顺
/// - `idle ≪ 总耗时` → 之前一直在动，只是最后这一步卡住了
///
/// 后者尤其要露出来：`docker pull` 刷完进度行之后卡在解压 / 落盘上，
/// 报「30s 没输出」比「等了 30s」有用得多。
pub fn IdleClock::report(self : IdleClock) -> CliRun {
  let now = @async.now()
  let elapsed = (now - self.started).to_int()
  let idle = (now - self.last).to_int()
  { code: -1, elapsed_ms: elapsed, idle_ms: idle, }
}

///|
/// 给一次调用套上**空闲**超时，并把底层 `Error` 收成 `Backend`。
///
/// 两条调用路径（收内存 / 收落盘）共用这个壳。与 `@async.with_timeout_opt`
/// 的区别在于那条钟会**重置**：每读到一块数据就重新开始计时，
/// 于是「慢但一直在动」的拉取不会被误杀，「彻底没动静」的才算超时。
///
/// 实现上不能只靠事件循环里的一条定时器：`with_timeout_opt` 的定时器是
/// 一次性的，没法中途续期。这里改成「轮询 + 取消」——每 `poll_ms` 看一眼
/// `clock.idle_ms`，超过预算就 `group.cancel()` 拆掉整组（子进程收 SIGKILL），
/// 没超就睡一小会儿再看。轮询粒度是 `poll_ms`，因此实际超时不会早于预算。
async fn[X] with_timeout(
  program : String,
  timeout_ms : Int32,
  clock : IdleClock,
  action : async () -> X,
) -> X raise DockerCliError {
  if timeout_ms <= 0 {
    return action() catch { err => raise Backend(program, -1, err.to_string()) }
  }
  let finished : X? = @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      while true {
        @async.sleep(poll_ms(timeout_ms))
        // 有人一直吐字节就别管它，接着盯
        if idle_ms(clock) < timeout_ms {
          continue
        }
        // 收网：给组里塞一个 `None` 结果并拆掉所有子任务，
        // 子进程跟着 `hard_cancel()` 一起收 SIGKILL
        group.return_immediately(None)
        return
      }
    })
    Some(action())
  }) catch {
    err => raise Backend(program, -1, err.to_string())
  }
  match finished {
    Some(result) => result
    // 组里的结果被换成 `None` = 我们按了停止键
    None => {
      let report = clock.report()
      raise Cancelled(program, idle_report(timeout_ms, report))
    }
  }
}

///|
/// 距离最后一次读到数据过去了多久（毫秒）。
fn idle_ms(clock : IdleClock) -> Int32 {
  (@async.now() - clock.last).to_int()
}

///|
/// 空闲监工的轮询粒度。
///
/// 取预算的 1/10，夹在 [50ms, 1s] 之间：预算小时反应够快（300ms 的用例
/// 不会真等满 300ms 才醒），预算大时也不会白白唤醒几十次。
fn poll_ms(timeout_ms : Int32) -> Int32 {
  let tenth = timeout_ms / 10
  if tenth < 50 {
    50
  } else if tenth > 1000 {
    1000
  } else {
    tenth
  }
}

///|
/// 超时那一刻，把「预算」与「实际空转了多久」写进 `Cancelled` 的原因位。
///
/// `Cancelled(name)` 原来只装一个程序名，`Show` 出来就是一句
/// `<program> was cancelled`。用户看这句的时候手上没有任何可用于判断的信息：
/// 是预算真的用完了，还是子进程一秒钟就被拆了？issue #94 里那条
/// `docker was cancelled` 就是卡在这里。
///
/// 现在钟量的是**空闲**，所以文案必须说清楚是「多久没动静」，
/// 而不是「一共花了多久」——后者在一条拉了五分钟大镜像的日志里毫无意义。
pub fn idle_report(budget_ms : Int32, report : CliRun) -> String {
  "no output for \{report.idle_ms}ms " +
  "(idle timeout \{budget_ms}ms, ran \{report.elapsed_ms}ms)"
}

///|
/// 单次调用。取消由外面那层 `with_timeout_opt` 负责：
/// 超时时整个任务组连同 `hard_cancel()` 一起被拆掉，子进程收 SIGKILL。
async fn run_once(
  program : String,
  args : Array[String],
  clock : IdleClock,
  sink~ : OutputSink = Memory,
) -> (Int32, Bytes, Bytes) raise DockerCliError {
  let grouped : (Int32, Bytes, Bytes) = @async.with_task_group(group => {
    // 管道必须「每次尝试都新开一对」：`read_from_process` 造出来的是
    // 独占写端，传给子进程后会由运行时自动关闭（`after_spawn`）。
    // 一次 spawn 失败就先把写端关掉了，若重试还拿同一对写端，
    // 子进程拿到的就是已经关掉的 fd —— 退出码 0，输出却是空的。
    let (spawned, out_read, err_read) = spawn_with_retry(
      group, program, args, clock,
    )
    // stdout 与 stderr **必须并发读干**：两边都是管道，容量只有几十 KB。
    // 先用一个 `read_all` 读干 stdout 再读 stderr，子进程一旦往 stderr 写满
    // 管道（`docker pull` 的进度、失败时的报错都能到这个量级）就会阻塞在写，
    // 于是永远不关 stdout，主进程卡在「等 stdout 的 EOF」上——双方互等。
    //
    // 两个读任务都要 `touch` 同一个 `clock`：它们才是「子进程还活着」的证据。
    // 只盯着 `wait` 是不行的——`docker pull` 会闷头写几分钟进度才退出。
    let stdout_task = group.spawn(() => read_to_bytes(out_read, clock, sink~))
    let stderr_task = group.spawn(() => read_to_bytes(err_read, clock))
    let stdout = stdout_task.wait()
    let stderr = stderr_task.wait()
    let code = wait_quiet(spawned)
    (code, stdout, stderr)
  }) catch {
    err => raise Backend(program, -1, err.to_string())
  }
  grouped
}

///|
/// spawn 一个子进程，返回 `(进程, stdout 读端, stderr 读端)`。
///
/// `ETXTBSY`（Text file busy）重试几次：刚写完就 exec 的脚本在某些文件系统上
/// 会撞上写句柄尚未释放。这在真实场景里也会遇到——`docker_cli` 的测试
/// 就是这么造 fake docker 的。
///
/// **每次尝试都重新开一对管道**：写端在传给子进程后由运行时自动关闭，
/// 一次失败的尝试会把它关掉；若沿用同一对写端重试，子进程拿到的是死 fd，
/// 表现成「退出码 0、输出为空」。调用方拿到的读端只属于成功那次尝试。
async fn[X] spawn_with_retry(
  group : @async.TaskGroup[X],
  program : String,
  args : Array[String],
  clock : IdleClock,
) -> (@process.Process, @process.ReadFromProcess, @process.ReadFromProcess) raise DockerCliError {
  let mut attempt = 0
  while true {
    let (out_read, out_write) = make_pipe()
    let (err_read, err_write) = make_pipe()
    let spawned : Result[@process.Process, Error] = try
      @process.spawn(
        group,
        program,
        args,
        stdin=null_stdin(),
        stdout=out_write,
        stderr=err_write,
        no_console_window~,
        cancel_handler=@process.hard_cancel(),
      )
    catch {
      err => Err(err)
    } noraise {
      proc => Ok(proc)
    }
    match spawned {
      Ok(proc) => {
        // 父进程侧必须关掉写端，否则 read_all 永远等不到 EOF
        out_write.close()
        err_write.close()
        // 起进程本身也算活动：否则「spawn 成功但还没吐出第一块数据」
        // 的那段时间会被算进空闲，把慢启动的容器误判成卡死
        clock.touch()
        return (proc, out_read, err_read)
      }
      Err(error) => {
        // 这次尝试作废，把它开的读端收掉，别攒 fd：
        // 写端已经由 `after_spawn` 在失败路径上关掉了。
        out_write.close()
        err_write.close()
        out_read.close()
        err_read.close()
        // 只有 ETXTBSY 值得重试；其余错误（文件不存在等）立刻上抛
        if !is_retryable_spawn_error(error) || attempt >= 20 {
          raise ExecutableNotFound("\{program}: \{error}")
        }
      }
    }
    attempt = attempt + 1
    @async.sleep(5)
  } nobreak {
    raise ExecutableNotFound(
      // while true 的体要么 return 要么 raise，这里的值守恒不到：
      // 保留一个显式失败，避免将来改动漏掉退出路径时静默死循环。
      program,
    )
  }
}

///|
/// `ETXTBSY` 是唯一值得重试的 spawn 失败：
/// 刚写完就 exec 的脚本在某些文件系统上会撞上写句柄尚未释放。
pub fn is_retryable_spawn_error(error : Error) -> Bool {
  error.to_string().contains("Text file busy")
}

///|
/// `@process.read_from_process()` 的薄封装：把底层 OSError 收成 `Backend`，
/// 调用方不必为「OS 层建管道失败」这种几乎不可能的事件单独分支。
fn make_pipe() -> (@process.ReadFromProcess, &@process.ProcessOutput) raise DockerCliError {
  @process.read_from_process() catch {
    err => raise Backend("pipe", -1, err.to_string())
  }
}

///|
/// 读干一个管道。
///
/// 自己一段段读、而不是 `read_all()`，是为了能**在重试时保住已读到的部分**：
/// `read_all()` 是一次性的，中途抛错就整体作废，重跑一遍会丢掉这一轮之前
/// 已经攒下的字节——对 `save` 出来的归档来说就是「退出码 0、输出为空」。
///
/// 为什么要重试：`EAGAIN` 是**可重试**的，不该上抛。`moonbitlang/async`
/// 的事件循环用边沿触发（`EPOLLET`）注册管道 fd，并发任务多时会出现
/// 「刚 `wait_read()` 返回、真正 `read(2)` 却拿到 `EAGAIN`」的窗口——
/// 就绪边沿已经被消费掉了。底层 `read_via_event_bus_unix` 只重试一次，
/// 第二次仍 `EAGAIN` 就把这个**瞬时**状态当成致命错抛出来。落到用户眼里是
/// 「cli:/usr/bin/docker — .../docker failed: read failed: OSError(...Resource
/// temporarily unavailable)」——明明子进程正常、归档就在管道里，
/// 却报了一个和「docker 用不了」长得一样的错。
///
/// 对「阻塞语义的读」来说 `EAGAIN` 本来就等于「这会儿没数据，待会儿再来」，
/// 所以这里让出一次、再读一遍；上限内没成功才当真正的故障。
///
/// 上限不宜大：管道对端是活着的子进程，正常情况下一次就能读完；
/// 真挂了（对端不写也不关）会走外面的超时，不该在这里空转。
async fn read_to_bytes(
  reader : @process.ReadFromProcess,
  clock : IdleClock,
  sink~ : OutputSink = Memory,
) -> Bytes raise DockerCliError {
  let out = @buffer.Buffer()
  let chunk = FixedArray::make(read_chunk_size, b'\x00')
  let mut failures = 0
  while true {
    let outcome : Result[Int32, Error] = try
      reader.read(chunk, offset=0, max_len=chunk.length())
    catch {
      err => Err(err)
    } noraise {
      n => Ok(n)
    }
    match outcome {
      // 读到 0 = 对端关了写端，EOF
      Ok(0) => break
      Ok(n) => {
        let data = chunk.unsafe_reinterpret_as_bytes()[:n].to_owned()
        // 落盘路径：边读边写，内存里不留整段归档
        match sink {
          Memory => out.write_bytes(data)
          Stream(writer) =>
            writer.write(data) catch {
              err => raise Backend("write", -1, err.to_string())
            }
        }
        // 读到东西 = 子进程还活着，空闲计时从这一刻重新算
        clock.touch()
        // 还读得出东西就说明没坏：把计数清零，
        // 别让早先一次卡顿一直攒着、最后把这里判成失败
        failures = 0
      }
      Err(err) => {
        if !is_transient_read_error(err) || failures >= read_retry_limit {
          raise Backend("read", -1, err.to_string())
        }
        failures = failures + 1
      }
    }
    // 让出一次事件循环：重试要等新的就绪边沿，空转重读拿不到数据。
    @async.sleep(read_retry_delay_ms)
  }
  out.to_bytes()
}

///|
/// 每次 `read` 的块大小。
let read_chunk_size : Int32 = 65536

///|
/// 连续 `EAGAIN` 的重试上限，见 `read_to_bytes`。
let read_retry_limit : Int32 = 64

///|
/// 连续 `EAGAIN` 之间的让出间隔（毫秒），见 `read_to_bytes`。
let read_retry_delay_ms : Int32 = 1

///|
/// 这条读错误是「暂时读不到」而不是「读坏了」吗？
///
/// `moonbitlang/async` 把 `EAGAIN` / `EWOULDBLOCK` / `EINPROGRESS` 都归为
/// 「非阻塞 IO 的暂时性错误」，`to_string()` 后都是 `Resource temporarily
/// unavailable`。按文案识别是因为这层只拿到 `Error`，类型信息已在
/// `catch` 那一步被抹掉了。
fn is_transient_read_error(err : Error) -> Bool {
  err.to_string().contains("Resource temporarily unavailable")
}

///|
/// `Process::wait` 的失败恒等于「子进程状态拿不到」，这里统一吞掉：
/// 出错时给 -1，让调用方按非零退出码处理。
async fn wait_quiet(proc : @process.Process) -> Int32 {
  proc.wait() catch {
    _ => -1
  }
}

///|
/// 跑一个子进程，把 stdout 直接写进文件，内存里不驻留整段归档。
///
/// 这是 issue #17「大镜像（>500MB 层）走流式路径」的落点：
/// `save` 出来的归档不应该先拼成 `Bytes` 再写盘。
/// 返回 (exit code, 写入字节数)。
///
/// stdout 走**管道 + 边读边写**，不是 `redirect_to_file` 直连文件：
/// 直连的话，父进程这边一个字节都看不见，`save` 一个大层花了三分钟
/// 和卡死了在它眼里一模一样——凡是「有输出就不该判超时」的语义都无从谈起。
/// 多一道路径的代价是父进程要搬一遍字节，换来的是**可观测**。
pub async fn run_cli_to_file(
  program : String,
  args : Array[String],
  output_path : String,
  timeout_ms : Int32,
) -> (Int32, Int32) raise DockerCliError {
  let clock = IdleClock::new()
  let file = @fs.open(
    output_path,
    mode=@fs.WriteOnly,
    create_mode=@fs.CreateMode::CreateOrTruncate,
  ) catch {
    err => raise Backend(program, -1, "cannot open output file: \{err}")
  }
  defer file.close()
  let (code, _, stderr, _) = run_capture(
    program,
    args,
    timeout_ms,
    sink=Stream(file),
    clock~,
  )
  if code != 0 {
    raise Backend(program, code, bytes_to_string(stderr))
  }
  let written = @fs.file_size(output_path) catch {
    err => raise Backend(program, -1, "cannot stat output file: \{err}")
  }
  (code, written.to_int())
}

///|
/// 子进程的 stdin：一个**立刻 EOF** 的空输入。
///
/// 原来这里写死 `@process.redirect_from_file("/dev/null")`，在 Windows 上是一行
/// 走不通的死码：那边没有 `/dev/null`，`open` 报 ENOENT，`spawn` 于是在真正
/// `CreateProcess` 之前就抛错。用户看到的是与 docker 毫无关系的
/// `OSError("@process.redirect_from_file(): \"/dev/null\": The system cannot
/// find the path specified.")`——issue #94 里那条报错就是这么来的。
///
/// `docker` / `podman` / `nerdctl` 的 `inspect` / `save` / `pull` 都不读 stdin，
/// 给个读到 EOF 的输入就够了，两个平台各用自己最便宜的做法。
///
/// POSIX 那半边要 await（`redirect_from_file` 是 async 的），所以整个函数
/// 也是 async 的。`try ... noraise` 是为了把底层 `Error` 收成 `Backend`：
/// 调用点在 `raise DockerCliError` 的上下文里，直接冒 `Error` 会类型不匹配，
/// 而「这台机器连 /dev/null 都打不开」也不值得单独给一种错误。
#cfg(not(platform="windows"))
async fn null_stdin() -> &@process.ProcessInput raise DockerCliError {
  let opened : Result[&@process.ProcessInput, Error] = try
    @process.redirect_from_file("/dev/null")
  catch {
    err => Err(err)
  } noraise {
    stdin => Ok(stdin)
  }
  match opened {
    Ok(stdin) => stdin
    Err(err) => raise Backend("null stdin", -1, err.to_string())
  }
}

///|
/// Windows 版：自己开一对管道，立刻把写端关掉。
///
/// 读端此刻就是「已到 EOF」，子进程不管怎么读都只会读到 0 字节。
/// 不用 `NUL` 设备文件：那要求子进程真的按路径打开一次设备，
/// 而这里连文件名都不用编。
///
/// 写端必须在这里关掉——不关，读端就永远等不到 EOF，
/// 子进程一旦读 stdin 会卡住，外面那层超时才收场。
#cfg(platform="windows")
fn null_stdin() -> &@process.ProcessInput raise {
  let (read_end, write_end) = @process.write_to_process()
  write_end.close()
  read_end
}

///|
/// 起子进程时要不要压掉新控制台窗口。
///
/// `@process.spawn` 的 `no_console_window` 默认关，非 Windows 上无副作用。
/// 不打开的话，`dive` 在 Windows 终端里每 `save` 一次都可能闪一个黑框——
/// 原版 dive 也是这么收的。
///
/// 平台判断和 `probe.mbt` 里的一致，用 `#cfg` 而不是运行时：
/// 这里只需要一个常量，不值得每次 spawn 都去翻环境变量。
#cfg(platform="windows")
let no_console_window : Bool = true

///|
#cfg(not(platform="windows"))
let no_console_window : Bool = false

///|
/// Engine 那条路（`http_unix.mbt`）量的是整次请求的时长，不是空闲时长：
/// 一次 `GET /images/x/get` 在服务端就可能长时间没有任何字节，
/// 但 socket 上并没有「子进程还活着」这种证据可看，只能按总时长收。
///
/// 文案与 `idle_report` 分开写，别把「等久了」说成「没输出」——
/// 对 socket 而言后者是错的。
pub fn elapsed_report(budget_ms : Int32, elapsed_ms : Int32) -> String {
  "gave up after \{elapsed_ms}ms of a \{budget_ms}ms budget"
}
