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
