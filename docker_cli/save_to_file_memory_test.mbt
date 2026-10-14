///|
/// `save_to_file` 的流式语义验证。
///
/// `cli_source_test.mbt` 里的 fake 归档只有几百字节——它能证明「功能对」，
/// 证明不了「不爆内存」。这里造一个 100MB 量级的 fixture，
/// 用 fake docker 把它吐给 `save_to_file`，再看进程内存有没有跟着涨。
///
/// 只面向 POSIX：内存读数来自 `/proc/self/status`。
#cfg(not(platform="windows"))
const LARGE_ARCHIVE_BYTES : Int32 = 100 * 1024 * 1024

///|
/// 进程的 (当前 RSS, 峰值 RSS)，单位 kB。
///
/// `VmRSS` 是当下占用，`VmHWM` 是进程启动以来的高水位。
/// 判断「这段归档有没有驻留内存」主要看 `VmRSS` 的前后差：
/// 写盘路径一旦把归档拼进内存，当前占用会立刻抬起来。
#cfg(not(platform="windows"))
async fn read_rss_kb() -> (Int32, Int32) raise DockerCliError {
  let text = @fs.read_file("/proc/self/status").text() catch {
    err => raise Backend("/proc/self/status", -1, "cannot read RSS: \{err}")
  }
  let mut rss = 0
  let mut hwm = 0
  for line in text.split("\n") {
    if line.has_prefix("VmRSS:") {
      rss = parse_first_kb(line)
    } else if line.has_prefix("VmHWM:") {
      hwm = parse_first_kb(line)
    }
  }
  (rss, hwm)
}

///|
/// 从 `VmRSS:\t  1234 kB` 里取出数字。
#cfg(not(platform="windows"))
fn parse_first_kb(line : StringView) -> Int32 {
  let mut digits = ""
  let mut started = false
  for code in line.to_array() {
    if code >= '0' && code <= '9' {
      digits = digits + code.to_string()
      started = true
    } else if started {
      break
    }
  }
  let mut value = 0
  for code in digits.to_array() {
    value = value * 10 + (code.to_int() - '0'.to_int())
  }
  value
}

///|
/// 大归档走 `save_to_file`：文件要完整落盘，内存不能跟着归档体积涨。
///
/// 断言分两层：
/// 1. 写出字节数与源归档一致（功能对）
/// 2. 写完之后当前 RSS 的增量远小于归档体积（没驻留）
///
/// 阈值给得宽松：100MB 归档如果真被拼进内存，RSS 至少涨 100MB；
/// 这里卡在 32MB，留出运行时缓冲 / 文件缓存的不确定性。
#cfg(not(platform="windows"))
async test "save_to_file streams a large archive without buffering it" {
  let dir = @fs.tmpdir(prefix="dive-bigsave-") catch {
    err => fail("tmpdir: \{err}")
  }
  let archive_path = "\{dir}/big.tar"
  let expected = @docker_cli.write_large_archive(
    archive_path,
    LARGE_ARCHIVE_BYTES,
  ) catch {
    err => fail("write_large_archive failed: \{err}")
  }
  // 生成器确实造出了 MB 量级的东西，否则这条用例没意义
  assert_true(expected >= LARGE_ARCHIVE_BYTES)

  let program = @docker_cli.write_fake_cli(
    @docker_cli.fake_cat_cli(archive_path),
  )
  let source = @docker_cli.DockerCliSource::new(program)
  let output = "\{dir}/out.tar"

  let (rss_before, _) = read_rss_kb() catch {
    err => fail("cannot read RSS before: \{err}")
  }
  let written = source.save_to_file("example:latest", output) catch {
    err => fail("save_to_file failed: \{err}")
  }
  // 目标文件大小与源归档字节数一致
  assert_eq(written, expected)
  assert_eq(@fs.file_size(output).to_int(), expected)

  let (rss_after, _) = read_rss_kb() catch {
    err => fail("cannot read RSS after: \{err}")
  }
  let growth = rss_after - rss_before
  // 归档被拼进内存的话，growth 会顶到 expected 量级；
  // 流式路径下 growth 只是 64KB 缓冲 + 运行时开销。
  let budget_kb = 32 * 1024
  if growth >= budget_kb {
    fail(
      "save_to_file retained the archive in memory: RSS grew \{growth} kB " +
      "for a \{expected} byte archive (budget \{budget_kb} kB)",
    )
  }
  @docker_cli.remove_fake_cli(program)
  @fs.rmdir(dir, recursive=true)
}
