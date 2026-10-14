///|
/// 连到一个 unix socket 路径，返回可异步读写的流。
///
/// 为什么不用 `@socket.Tcp::connect_to_host`：它内部先做 `getaddrinfo`，
/// 面向 `host:port`，永远解析不出 unix socket 路径。
/// Engine API 的地址是 `/var/run/docker.sock` 这种文件路径，
/// 只能自己收口 `socket(AF_UNIX, ...)` + `connect(2)`。
///
/// C 侧只负责建连并返回一个 non-blocking fd，
/// 读写交给 `@raw_fd.RawFdStream`（实现 `@io.Reader` / `@io.Writer`）。
///
/// 本包因此只支持 native：unix socket 与 `@raw_fd` 都只在 native 上有入口。
/// 只读 tar / 只用 CLI 后端的场景不受影响，那是上层用不用 Engine 后端的事。
#cfg(not(platform="windows"))
#borrow(path)
extern "C" fn unix_connect_ffi(path : Bytes) -> Int32 = "dive_unix_connect"

///|
/// 关闭一个裸 fd（建连失败之外的收尾路径用）。
#cfg(not(platform="windows"))
extern "C" fn unix_close_ffi(fd : Int32) -> Int32 = "dive_unix_close"

///|
/// 连到 `path` 上的 unix socket。
///
/// 失败一律收成 `Backend`：unix socket 上「连不上」通常意味着 daemon 没起，
/// 错误信息要让用户看懂是路径不对还是 daemon 不在。
#cfg(not(platform="windows"))
pub async fn connect_unix_socket(
  path : String,
) -> @raw_fd.RawFdStream raise DockerCliError {
  let fd = unix_connect_ffi(@utf8.encode(path))
  if fd < 0 {
    raise Backend(path, -1, "connect failed: errno \{-fd}")
  }
  @raw_fd.RawFdStream(fd) catch {
    err => raise Backend(path, -1, "connect failed: \{err}")
  }
}

///|
/// 关掉一个裸 fd。
#cfg(not(platform="windows"))
pub fn close_unix_fd(fd : Int32) -> Unit {
  ignore(unix_close_ffi(fd))
}
