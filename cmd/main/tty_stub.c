/*
 * 「stdin / stdout 是不是终端」的最小 C 入口。
 *
 * 为什么在 C 里问：`isatty` 是 libc 的事，MoonBit 的 core 没有对等的能力，
 * 而这件事必须在**进 alternate screen 之前**得到答案——`Tty::stdio()` 只是把 fd
 * 包一层，真正炸的是 `with_raw_mode` 里的 `tcgetattr`。等到那时再报错，
 * `\e[?1049h` 已经发出去了，终端会先切屏、再在主屏上打一行错误。
 *
 * 与 `registry_cli/stderr_stub.c` 里的 `dive_stderr_is_tty` 同一套写法：
 * Windows 上没有 `isatty`，一律答「不是终端」，界面这一档自然退到文本。
 */
#include <stdio.h>
#include <stdint.h>
#include <moonbit.h>

#ifndef _WIN32
#include <unistd.h>
#endif

MOONBIT_FFI_EXPORT
int32_t dive_stdin_is_tty(void) {
#ifdef _WIN32
  return 0;
#else
  return isatty(fileno(stdin)) ? 1 : 0;
#endif
}

MOONBIT_FFI_EXPORT
int32_t dive_stdout_is_tty(void) {
#ifdef _WIN32
  return 0;
#else
  return isatty(fileno(stdout)) ? 1 : 0;
#endif
}
