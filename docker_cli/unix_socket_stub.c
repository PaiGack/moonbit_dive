/*
 * `AF_UNIX` socket 的最小 C 入口。
 *
 * `moonbitlang/async/socket` 只有 TCP / UDP 绑定：`Tcp::connect_to_host`
 * 走 DNS 解析，永远连不上 unix socket 路径。Engine 后端要连
 * `/var/run/docker.sock`，只能绕过它自己收口 socket(2) / connect(2)。
 *
 * 返回约定：>= 0 是 fd，< 0 是 -errno。调用方拿到 fd 后交给
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
int32_t dive_unix_connect(const char *path) {
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  /*|
  `sun_path` 只有 108 字节，超了会截断 bind / connect 到另一个路径；
  显式挡掉，免得后面看到莫名其妙的连接失败。
  */
  if (strlen(path) >= sizeof(addr.sun_path)) {
    return -ENAMETOOLONG;
  }
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return -errno;
  }
  dive_unix_set_nonblocking(fd);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  return fd;
}

/*|
关掉一个 fd。
*/
MOONBIT_FFI_EXPORT
int32_t dive_unix_close(int32_t fd) {
  return close(fd);
}

#endif
