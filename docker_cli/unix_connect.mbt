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
/// **这里故意不加 `#cfg(not(platform="windows"))`。** FFI 声明一旦被 cfg 掉，
/// 调用它的地方在 Windows 上就退化成「标识符未绑定」，跟着报一串
/// `connect_error(socket_path, err)` 的类型不匹配——报错指向的是调用方，
/// 真凶却在几百行外。所以声明和包装都留着，把平台差异收在 C 侧：
/// `unix_socket_stub.c` 在 `_WIN32` 下返回 `-EPROTONOSUPPORT`，
/// 用户看到的是一条「这台机器没有 unix socket」的 `Backend`，
/// 而不是编译不过。本包仍只对 native 构建（见 `moon.pkg`）。
#borrow(path)
extern "C" fn unix_connect_ffi(path : Bytes) -> Int32 = "dive_unix_connect"

///|
/// 关闭一个裸 fd（建连失败之外的收尾路径用）。
extern "C" fn unix_close_ffi(fd : Int32) -> Int32 = "dive_unix_close"

///|
/// 连到 `path` 上的 unix socket。
///
/// 失败一律收成 `Backend`：unix socket 上「连不上」通常意味着 daemon 没起，
/// 错误信息要让用户看懂是路径不对还是 daemon 不在。
pub async fn connect_unix_socket(
  path : String,
) -> @raw_fd.RawFdStream raise DockerCliError {
  let encoded = @utf8.encode(path)
  connect_unix_socket_bytes(encoded, path)
}

///|
/// `connect_unix_socket` 的字节版：路径已经是 `Bytes` 时省一次编码。
///
/// `#borrow` 只对 `Bytes` 生效，所以 FFI 只在这一层被调用；
/// `display` 是原样的路径文本，报错时要念给用户看。
pub async fn connect_unix_socket_bytes(
  path : Bytes,
  display : String,
) -> @raw_fd.RawFdStream raise DockerCliError {
  let fd = unix_connect_ffi(path)
  if fd < 0 {
    raise Backend(display, -1, "connect failed: errno \{-fd}")
  }
  @raw_fd.RawFdStream(fd) catch {
    err => raise Backend(display, -1, "connect failed: \{err}")
  }
}

///|
/// 关掉一个裸 fd。
pub fn close_unix_fd(fd : Int32) -> Unit {
  ignore(unix_close_ffi(fd))
}
