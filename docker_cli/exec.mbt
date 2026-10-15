///|
/// 跑一个子进程并收集 stdout / stderr。
///
/// 走 `read_from_process` 而不是 `collect_output`：save 出来的归档动辄几百 MB，
/// 不能让运行时把它整段拼成 `String` 再转回 `Bytes`。
/// 这里的返回值仍全量驻留内存，落盘版本留给后续。
///
/// 超时包的是**整个「spawn + 读两个流 + wait」**，不只是 `wait`：
/// 一个只写 stdout 不退出、或者写了就不关 fd 的子进程，
/// 光等 `wait` 是等不到超时的。
pub async fn run_cli(
  program : String,
  args : Array[String],
  timeout_ms : Int32,
) -> (Int32, Bytes, Bytes) raise DockerCliError {
  with_timeout(program, timeout_ms, () => run_once(program, args))
}

///|
/// 给一次调用套上超时，并把底层 `Error` 收成 `Backend`。
///
/// 两条调用路径（收内存 / 收落盘）共用这个壳：超时的**边界**必须是
/// 「整次调用」，不能只包 `wait`——子进程写了 stdout 却不退出时，
/// 光等 `wait` 是等不到超时的。
async fn[X] with_timeout(
  program : String,
  timeout_ms : Int32,
  action : async () -> X,
) -> X raise DockerCliError {
  if timeout_ms > 0 {
    let finished = @async.with_timeout_opt(timeout_ms, action) catch {
      err => raise Backend(program, -1, err.to_string())
    }
    match finished {
      Some(result) => result
      None => raise Cancelled(program)
    }
  } else {
    action() catch {
      err => raise Backend(program, -1, err.to_string())
    }
  }
}

///|
/// 单次调用。取消由外面那层 `with_timeout_opt` 负责：
/// 超时时整个任务组连同 `hard_cancel()` 一起被拆掉，子进程收 SIGKILL。
async fn run_once(
  program : String,
  args : Array[String],
) -> (Int32, Bytes, Bytes) raise DockerCliError {
  let grouped : (Int32, Bytes, Bytes) = @async.with_task_group(group => {
    // 管道必须「每次尝试都新开一对」：`read_from_process` 造出来的是
    // 独占写端，传给子进程后会由运行时自动关闭（`after_spawn`）。
    // 一次 spawn 失败就先把写端关掉了，若重试还拿同一对写端，
    // 子进程拿到的就是已经关掉的 fd —— 退出码 0，输出却是空的。
    let (spawned, out_read, err_read) = spawn_with_retry(group, program, args)
    // stdout 与 stderr **必须并发读干**：两边都是管道，容量只有几十 KB。
    // 先用一个 `read_all` 读干 stdout 再读 stderr，子进程一旦往 stderr 写满
    // 管道（`docker pull` 的进度、失败时的报错都能到这个量级）就会阻塞在写，
    // 于是永远不关 stdout，主进程卡在「等 stdout 的 EOF」上——双方互等。
    let stdout_task = group.spawn(() => read_to_bytes(out_read))
    let stderr_task = group.spawn(() => read_to_bytes(err_read))
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
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=out_write,
        stderr=err_write,
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
async fn read_to_bytes(
  reader : @process.ReadFromProcess,
) -> Bytes raise DockerCliError {
  let data = reader.read_all() catch {
    err => raise Backend("read", -1, err.to_string())
  }
  data.binary()
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
pub async fn run_cli_to_file(
  program : String,
  args : Array[String],
  output_path : String,
  timeout_ms : Int32,
) -> (Int32, Int32) raise DockerCliError {
  with_timeout(program, timeout_ms, () => {
    run_to_file_once(program, args, output_path)
  })
}

///|
/// 单次落盘调用。stdout 走 `redirect_to_file`，数据不经过进程内存。
///
/// 与收内存那条路一样，**每次 spawn 尝试都新开 stderr 管道与 stdout 文件重定向**：
/// 两者传进子进程后都会由运行时自动关闭（`after_spawn`），
/// 一次失败尝试之后不能再复用，否则子进程拿到死 fd、归档写不出来。
async fn run_to_file_once(
  program : String,
  args : Array[String],
  output_path : String,
) -> (Int32, Int32) raise DockerCliError {
  let grouped : (Int32, Int32) = @async.with_task_group(group => {
    let (spawned, err_read) = spawn_to_file_with_retry(
      group, program, args, output_path,
    )
    let stderr = read_to_bytes(err_read)
    let code = wait_quiet(spawned)
    if code != 0 {
      raise Backend(program, code, bytes_to_string(stderr))
    }
    let written = @fs.file_size(output_path) catch {
      err => raise Backend(program, -1, "cannot stat output file: \{err}")
    }
    (code, written.to_int())
  }) catch {
    err => raise Backend(program, -1, err.to_string())
  }
  grouped
}

///|
/// `spawn_with_retry` 的落盘版：stdout 直接重定向到文件，
/// 返回 `(进程, stderr 读端)`。每次尝试都重开 stderr 管道与 stdout 重定向。
async fn[X] spawn_to_file_with_retry(
  group : @async.TaskGroup[X],
  program : String,
  args : Array[String],
  output_path : String,
) -> (@process.Process, @process.ReadFromProcess) raise DockerCliError {
  let mut attempt = 0
  while true {
    let (err_read, err_write) = make_pipe()
    let stdout = @process.redirect_to_file(
      output_path,
      create_mode=@fs.CreateMode::CreateOrTruncate,
    ) catch {
      err => {
        err_write.close()
        err_read.close()
        raise Backend(program, -1, "cannot open output file: \{err}")
      }
    }
    let spawned : Result[@process.Process, Error] = try
      @process.spawn(
        group,
        program,
        args,
        stdin=@process.redirect_from_file("/dev/null"),
        stdout~,
        stderr=err_write,
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
        err_write.close()
        return (proc, err_read)
      }
      Err(error) => {
        // 这次尝试作废：写端/重定向已由 `after_spawn` 关掉，收掉读端别攒 fd
        err_write.close()
        err_read.close()
        if !is_retryable_spawn_error(error) || attempt >= 20 {
          raise ExecutableNotFound("\{program}: \{error}")
        }
      }
    }
    attempt = attempt + 1
    @async.sleep(5)
  } nobreak {
    raise ExecutableNotFound(program)
  }
}
