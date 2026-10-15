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
