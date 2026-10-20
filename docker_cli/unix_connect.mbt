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
/// `unix_socket_stub.c` 在 `_WIN32` 下把 `EPROTONOSUPPORT` 写进 `err_out`，
/// 用户看到的是一条「这台机器没有 unix socket」的 `Backend`，
/// 而不是编译不过。本包仍只对 native 构建（见 `moon.pkg`）。
///
/// 错误走 out 参数、fd 走返回值。`@types.Fd` 在 Windows 上是不透明的
/// `HANDLE`（`#external`），没法拿它跟 0 比大小，所以「失败」不能靠
/// 返回负数表达：C 侧把 `errno` 写进 `err_out`，返回 0 表示成功。
#borrow(path, err_out)
extern "C" fn unix_connect_ffi(path : Bytes, err_out : Ref[Int32]) -> @types.Fd = "dive_unix_connect"

///|
/// 关闭一个裸 fd（建连失败之外的收尾路径用）。
extern "C" fn unix_close_ffi(fd : @types.Fd) -> Int32 = "dive_unix_close"

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
  let err : Ref[Int32] = Ref(0)
  let fd = unix_connect_ffi(path, err)
  if err.val != 0 {
    raise Backend(
      display,
      err.val,
      "connect failed: \{unix_errno_hint(err.val)}",
    )
  }
  @raw_fd.RawFdStream(fd) catch {
    err => raise Backend(display, -1, "connect failed: \{err}")
  }
}

///|
/// 把 connect 的 errno 翻成一句人能读的话。
///
/// 用户看到的通常是「连不上 daemon」，但原因可能差很远：
/// 路径不存在、权限不够、对端不是 socket、平台压根没有 unix socket。
/// 只报数字等于让用户自己去查 errno 表。
fn unix_errno_hint(errno : Int32) -> String {
  let hint = match errno {
    2 => "no such file (daemon not running?)"
    13 => "permission denied (check socket ownership)"
    88 => "not a socket"
    111 => "connection refused (daemon not listening)"
    93 => "protocol not supported (this platform has no unix socket)"
    _ => "unknown reason"
  }
  "\{hint}, errno \{errno}"
}

///|
/// 关掉一个裸 fd。
///
/// 参数用 `@types.Fd` 而不是 `Int32`：Windows 上它是不透明的 `HANDLE`，
/// 这里只是把同一个句柄原样交给 C，不假装它是个整数。
pub fn close_unix_fd(fd : @types.Fd) -> Unit {
  ignore(unix_close_ffi(fd))
}
