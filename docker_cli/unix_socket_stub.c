/*
 * `AF_UNIX` socket 的最小 C 入口。
 *
 * `moonbitlang/async/socket` 只有 TCP / UDP 绑定：`Tcp::connect_to_host`
 * 走 DNS 解析，永远连不上 unix socket 路径。Engine 后端要连
 * `/var/run/docker.sock`，只能绕过它自己收口 socket(2) / connect(2)。
 *
 * 返回约定：fd 走返回值，失败时返回值无意义，errno 写进 `err_out`
 * （0 表示成功）。不用「返回负数表示错误」是因为 Windows 上
 * `@types.Fd` 是不透明的 `HANDLE`，没法比大小。调用方拿到 fd 后交给
 * `@raw_fd.RawFdStream`（它实现 `@io.Reader` / `@io.Writer`），
 * 后续读写走事件循环，不再需要 FFI。
 *
 * fd 一律设成 non-blocking：`@raw_fd.RawFd` 假定 fd 是异步的，
 * 阻塞 fd 会把整个事件循环卡死。
 */
#ifndef _WIN32

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <moonbit.h>

/*|
把 fd 设成 non-blocking。`@raw_fd.RawFd` 在非阻塞 fd 上挂事件循环轮询；
漏了这一步，connect / read 会阻塞住整个运行时。
*/
static void dive_unix_set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags >= 0) {
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  }
}

/*|
建一个 AF_UNIX socket 并连到 `path`，返回连接 fd。
*/
MOONBIT_FFI_EXPORT
intptr_t dive_unix_connect(const char *path, int32_t *err_out) {
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  /*|
  `sun_path` 只有 108 字节，超了会截断 bind / connect 到另一个路径；
  显式挡掉，免得后面看到莫名其妙的连接失败。
  */
  if (strlen(path) >= sizeof(addr.sun_path)) {
    *err_out = ENAMETOOLONG;
    return 0;
  }
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    *err_out = errno;
    return 0;
  }
  dive_unix_set_nonblocking(fd);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int err = errno;
    close(fd);
    *err_out = err;
    return 0;
  }
  return fd;
}

/*|
关掉一个 fd。
*/
MOONBIT_FFI_EXPORT
int32_t dive_unix_close(intptr_t fd) {
  return close((int)fd);
}

#else
/*
Windows 分支：符号得在，行为要明确。

MoonBit 侧的 FFI 声明（`unix_connect.mbt`）不按平台裁剪——裁掉之后调用方
会报「标识符未绑定」，那串报错的落点离真凶很远。所以平台差异收在这里：
把 `EPROTONOSUPPORT` 写进 `err_out`，调用方把它渲染成一条能读懂的 `Backend`。
Windows 上本来也没有 `/var/run/docker.sock`，报「这台机器没有 unix socket」
比报「编译不过」更接近事实。

`WSASocket(AF_UNIX)` 是 Win10 1803 之后才有的东西，不走它：
Engine 后端在 Windows 上是 CLI 子进程那条路，不走 socket。
*/
#include <stdint.h>
#include <moonbit.h>

#ifndef EPROTONOSUPPORT
#define EPROTONOSUPPORT 93
#endif

MOONBIT_FFI_EXPORT
intptr_t dive_unix_connect(const char *path, int32_t *err_out) {
  (void)path;
  *err_out = EPROTONOSUPPORT;
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t dive_unix_close(intptr_t fd) {
  (void)fd;
  return -1;
}

#endif
