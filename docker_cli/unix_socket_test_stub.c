/*
 * 测试专用的 AF_UNIX 服务端 stub。
 *
 * `moonbitlang/async/socket` 只有 TCP / UDP 绑定，没有 listen / accept，
 * Engine 后端的传输层测试起不了 fake daemon。这里补上建监听、accept。
 *
 * 生产侧只需要 connect（见 `unix_socket_stub.c`），别把 listen / accept 混进去——
 * 成品包里没有「起一个 daemon」的需求。
 *
 * 返回值约定：>= 0 是 fd，< 0 是 -errno。fd 一律 non-blocking。
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
non-blocking：`@raw_fd.RawFd` 假定 fd 异步，阻塞会卡死事件循环。
*/
static void dive_unix_test_set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags >= 0) {
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  }
}

/*|
在 `path` 上建 AF_UNIX 监听 socket。
*/
MOONBIT_FFI_EXPORT
int32_t dive_unix_test_listen(const char *path) {
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(addr.sun_path)) {
    return -ENAMETOOLONG;
  }
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return -errno;
  }
  /*|
  上一轮测试留下的 socket 文件会让 bind 撞上 EADDRINUSE；
  tmpdir 里的路径理论上不重名，但 unlink 一次更省心。
  */
  unlink(path);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  if (listen(fd, 8) < 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  dive_unix_test_set_nonblocking(fd);
  return fd;
}

/*|
从监听 socket 上 accept 一个连接。没有待处理连接时返回 -EAGAIN。
*/
MOONBIT_FFI_EXPORT
int32_t dive_unix_test_accept(int32_t listen_fd) {
  int fd = accept(listen_fd, 0, 0);
  if (fd < 0) {
    return -errno;
  }
  dive_unix_test_set_nonblocking(fd);
  return fd;
}

#endif
