///|
/// 白盒直击 `spawn_with_retry` 的重试分支。
///
/// 复现手法：对一个脚本文件**保持写句柄**（用 `@fs.open` 拿到 `File` 不关闭），
/// 此时 `execve` 返回 `ETXTBSY`（Text file busy）。这正是 CI 上
/// 「刚写完 fake docker 脚本就 exec」会撞到的错误。
///
/// 第一次 spawn 必然 ETXTBSY → 运行时的 `after_spawn` 会把写端关掉；
/// 修复前重试沿用这对已关闭的写端，子进程输出为空（退出码 0）；
/// 修复后每次尝试都新开管道，句柄释放后的重试能正常拿到输出。
#cfg(not(platform="windows"))
async test "spawn_with_retry recovers from ETXTBSY and keeps the output" {
  let program = write_fake_cli("#!/bin/sh\ncat /etc/hostname\n")
  // 保持写句柄打开 → exec 该文件会 ETXTBSY
  let held = @fs.open(program, mode=@fs.Mode::ReadWrite) catch {
    err => fail("cannot hold write handle: \{err}")
  }
  let releaser = @async.with_task_group(group => {
    ignore(
      group.spawn(() => {
        @async.sleep(50)
        held.close()
      }),
    )
    // 重试间隔 5ms，20 次上限约 100ms，够等到句柄释放
    run_cli(program, ["save", "x"], 0) catch {
      err => fail("run_cli should recover from ETXTBSY: \{err}")
    }
  })
  let (code, stdout, _stderr) = releaser
  assert_eq(code, 0)
  assert_true(stdout.length() > 0)
  remove_fake_cli(program)
}

///|
/// stderr 写满管道时 `run_cli` 不能死锁。
///
/// 复现手法：子进程往 stderr 写远超管道缓冲（Linux 上 64KB）的内容，
/// stdout 只写一点点。如果实现是「先读干 stdout，再读 stderr」，
/// 子进程会在写 stderr 时被阻塞、永远不关 stdout，主进程于是卡在
/// 「等 stdout 的 EOF」上——双方互等，`run_cli` 永不返回。
///
/// `--pull` 引入的 `<tool> pull <ref>` 就是会吐大量 stderr 的那类命令，
/// 这个用例守住「两个流并发读干」这条约束。
#cfg(not(platform="windows"))
async test "run_cli does not deadlock when stderr floods the pipe" {
  let script =
    #|#!/bin/sh
    #|echo hello
    #|i=0
    #|while [ $i -lt 20000 ]; do
    #|  echo "noise noise noise noise noise noise noise noise noise noise" >&2
    #|  i=$((i+1))
    #|done
    #|
  let program = write_fake_cli(script)
  // 真的并发读的话秒回；死锁的话会一直等，5 秒足够区分
  let result = @async.with_timeout_opt(5000, () => {
    run_cli(program, [], 0) catch {
      err => fail("run_cli failed: \{err}")
    }
  }) catch {
    err => fail("unexpected error: \{err}")
  }
  match result {
    Some((code, stdout, stderr)) => {
      assert_eq(code, 0)
      assert_true(stdout.length() > 0)
      // 20000 行 × ~60 字节 ≈ 1.2MB，远大于管道缓冲
      assert_true(stderr.length() > 65536)
    }
    None =>
      fail("run_cli deadlocked: stderr flooded the pipe and blocked the child")
  }
  remove_fake_cli(program)
}

///|
/// 分块读要把跨块边界的字节原样拼回来。
///
/// `read_to_bytes` 改成一段段读、为的是**重试时能保住已读到的部分**：
/// `read_all()` 是一次性的，中途抛错整体作废，重跑一遍会丢掉这一轮之前
/// 攒下的字节——对 `save` 出来的归档就是「退出码 0、输出为空」。
/// 这个用例守住拼接语义：子进程吐的长度跨过多个 `read_chunk_size`。
#cfg(not(platform="windows"))
async test "chunked read reassembles bytes across chunk boundaries" {
  // 刻意不是块大小的整数倍，最后一块是短读
  let payload = "abcdefghij".repeat(20_000)
  let script =
    #|#!/bin/sh
    #|cat PAYLOAD_PATH
    #|
  let payload_path = write_temp_bytes("chunked.txt", @utf8.encode(payload))
  let program = write_fake_cli(
    script.replace(old="PAYLOAD_PATH", new=payload_path),
  )
  let (code, stdout, _stderr) = run_cli(program, [], 0) catch {
    err => fail("run_cli failed: \{err}")
  }
  assert_eq(code, 0)
  assert_eq(@utf8.decode(stdout), payload)
  remove_fake_cli(program)
  remove_temp_bytes(payload_path)
}

///|
/// 子进程的 stdin 必须是「立刻 EOF」，而不是一个打不开的路径。
///
/// 守的是 issue #94 的根因：这里原来写死 `redirect_from_file("/dev/null")`，
/// 在 Windows 上 `open` 直接 ENOENT，`spawn` 连 `CreateProcess` 都没走到就抛错，
/// 用户拿到的是一句与 docker 无关的
/// `OSError("@process.redirect_from_file(): \"/dev/null\": ...")`。
///
/// 两个平台各有一份实现（`#cfg`），但契约是同一条：
/// 给的是什么路径不重要，子进程读 stdin **立刻就是 EOF**、不卡住。
async test "child stdin is an immediate EOF, not a device path" {
  let program = write_fake_cli(
    "#!/bin/sh\nwc -c < /dev/stdin 2>/dev/null || echo 0\n",
  )
  let (code, stdout, _stderr) = run_cli(program, [], 0) catch {
    err => fail("run_cli should not fail on its own stdin: \{err}")
  }
  assert_eq(code, 0)
  assert_eq(@utf8.decode(stdout).trim(), "0")
  remove_fake_cli(program)
}

///|
/// 超时的 `Cancelled` 必须带上「多久没输出 / 预算 / 总共跑了多久」。
///
/// 守的是 issue #94 的最后一层：用户拿到 `docker was cancelled` 时，
/// 手上没有任何东西能判断到底发生了什么。三个数并排写出来，
/// 一眼就能分辨「一句话都没有」和「一直在动、只是最后卡住了」。
async test "timed-out cancellation reports the idle budget and the total run" {
  let program = write_fake_cli("#!/bin/sh\nsleep 5\n")
  let error = try {
    run_cli(program, ["pull", "x"], 300) |> ignore
    fail("run_cli should time out")
  } catch {
    err => err
  }
  let text = error.to_string()
  assert_true(text.contains("was cancelled"))
  // 预算原样报出来：用户能据此判断该不该调大 --timeout
  assert_true(text.contains("300ms"))
  // 「多久没动静」单独报：这才是这次钟真正量的东西
  assert_true(text.contains("no output for"))
  assert_true(text.contains("ran"))
  remove_fake_cli(program)
}

///|
/// **有输出就不该超时**（issue #94 的直接回归）。
///
/// 这条钟量的是空闲，不是总时长：子进程一直往外吐字节就不算「卡住」，
/// 哪怕总共跑得比预算久得多。修之前 `docker pull` 拉一个正经镜像
/// （几十秒、进度一直在刷）会被 30 秒的总时长硬砍，日志停在
/// `pulling ...` 上，看起来像网络挂了。
///
/// 脚本每 0.1 秒吐一行、连吐 20 次（≈2 秒），预算只给 400ms：
/// 旧的「总时长」语义下这条半秒内就炸；新语义下必须正常跑完。
///
/// 间隔（0.1s）要明显小于预算（0.4s），否则测的就不是「有输出不超时」，
/// 而是「偶尔抖一下算不算卡死」——那是另一件事，别混进来。
async test "a child that keeps writing is never treated as timed out" {
  let program = write_fake_cli(
    "#!/bin/sh\ni=0\nwhile [ $i -lt 20 ]; do echo \"chunk $i\"; sleep 0.1; i=$((i+1)); done\n",
  )
  let (code, stdout, _stderr) = run_cli(program, ["pull", "x"], 400) catch {
    err => fail("steady output must not be cancelled: \{err}")
  }
  assert_eq(code, 0)
  // 20 行都在，说明中途没有被拆掉
  let lines = @utf8.decode(stdout).trim().split("\n").collect()
  assert_eq(lines.length(), 20)
  remove_fake_cli(program)
}

///|
/// 反过来说，吐了几口之后就彻底没动静的那次，仍然要按空闲超时收掉。
///
/// 两条一起看才算把语义钉住：`docker pull` 刷完进度行卡在别处、
/// 对端不写也不关，正是这条钟该管的事。
async test "silence after some output still times out" {
  let program = write_fake_cli("#!/bin/sh\necho started\nsleep 10\n")
  let error = try {
    run_cli(program, ["pull", "x"], 400) |> ignore
    fail("silence should time out")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("was cancelled"))
  remove_fake_cli(program)
}

///|
/// 收数据的一侧也在算「还活着」：写盘慢 ≠ 子进程卡死。
///
/// 这条守的是 issue #94 里 `docker save` 被砍的真正原因。`save` 是**安静**的
/// ——它一个字节都不往 stderr 写，只是闷头往管道里倒归档。父进程每收一块
/// 都要落盘 / 算哈希，管道因此会短暂空掉；如果空闲钟只认「子进程写没写」，
/// 这段「我们在忙」就会被算成静默，几轮下来撞上 30 秒上限，
/// 用户看到的就是 `docker save ...: no output for 30000ms`。
///
/// `StreamTicking` 让收数据方在写完之后自己 `touch` 一次：只要归档还在流进来，
/// 这次调用就不该被判死。这里用一个「吐几块就慢下来」的假子进程钉住它。
#cfg(not(platform="windows"))
async test "a slow sink still counts as activity" {
  let payload = "sink".repeat(200_000)
  let payload_path = write_temp_bytes("slow-sink.txt", @utf8.encode(payload))
  // 每 32KB 停 0.15 秒：子进程一直有数据在手，只是推得慢
  let program = write_fake_cli(
    "#!/bin/sh\ni=0\nwhile [ $i -lt 6 ]; do dd if=PAYLOAD bs=32768 skip=$i count=1 iflag=fullblock 2>/dev/null; sleep 0.15; i=$((i+1)); done\n".replace(
      old="PAYLOAD",
      new=payload_path,
    ),
  )
  let sink_path = write_temp_bytes("slow-sink-out.bin", b"")
  let file = @fs.open(sink_path, mode=@fs.Mode::ReadWrite) catch {
    err => fail("cannot open sink: \{err}")
  }
  let clock = IdleClock::new()
  // 预算 400ms，整段要跑 ≈0.9s：按「总耗时」必被判死，
  // 按「收数据即活动」则必须跑完
  // `i=0` 不能省：脚本以 `#!/bin/sh` 起（测试环境里是 dash），未定义变量
  // 在 `[ $i -lt 6 ]` 里是直接报错退出的——测出来的「没输出」会是假的。
  // `iflag=fullblock` 同理：管道语义下每段只有 4KB，不给它 dd 会「有多少读多少」，
  // 几轮就读到 EOF，测的就不是「慢」而是「短」。
  let (code, _, _stderr, report) = run_capture(
    program,
    [],
    400,
    sink=StreamTicking(file, clock),
    clock~,
  ) catch {
    err => fail("a slow sink must not be cancelled: \{err}")
  }
  assert_eq(code, 0)
  file.close()
  let written = @fs.file_size(sink_path) catch { err => fail("stat: \{err}") }
  assert_true(written > 0)
  // 整段比预算久一倍多，却只被判过一次「等」，最长静默远小于预算：
  // 这就是「收数据即活动」该有的样子
  assert_true(report.elapsed_ms > 800)
  assert_true(report.peak_idle_ms < 400)
  remove_fake_cli(program)
  remove_temp_bytes(payload_path)
  remove_temp_bytes(sink_path)
}
