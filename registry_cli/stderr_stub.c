/*
 * 往 stderr 写一段字节的最小 C 入口。
 *
 * 进度行是「同步回调里画一行」，而 `moonbitlang/async` 的写接口全是 async 的：
 * 为了画一行去 spawn 一个任务、再等它调度一轮，进度就永远慢半拍。这里直接
 * `write(2)`：进度行只有几十字节，终端 / 管道缓冲装得下；装不下就丢掉这一次，
 * 下一格还会再来，不需要重试。
 *
 * 返回实际写出的字节数，失败返回 -1。
 */
#include <stdio.h>
#include <stdint.h>
#include <moonbit.h>

#ifndef _WIN32
#include <unistd.h>
#endif

MOONBIT_FFI_EXPORT
int32_t dive_write_stderr(const uint8_t *buf, int32_t len) {
  if (len <= 0) {
    return 0;
  }
  size_t written = fwrite((const void *)buf, 1, (size_t)len, stderr);
  if (written == 0) {
    fflush(stderr);
    return -1;
  }
  /*|
   * 进度行要立刻可见，攒在 libc 缓冲里就白画了。
   */
  fflush(stderr);
  return (int32_t)written;
}

MOONBIT_FFI_EXPORT
int32_t dive_stderr_is_tty(void) {
#ifdef _WIN32
  /*|
   * Windows 上没有 isatty；控制台判断要 GetConsoleMode，
   * 而这里只关心「要不要用 \r 原地重画」，退化成「不打进度条」最稳。
   */
  return 0;
#else
  return isatty(fileno(stderr)) ? 1 : 0;
#endif
}
