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
/// 错误走 out 参数、fd 走返回值。`@types.Fd` 在 Windows 上是不透明的
/// `HANDLE`（`#external`），没法拿它跟 0 比大小，所以「失败」不能靠
/// 返回负数表达：C 侧把 `errno` 写进 `err_out`，返回 0 表示成功。
///
/// 平台差异分两层：**公开入口两个平台都在**（`connect_unix_socket_bytes`），
/// FFI 与真正的建连只对 POSIX 编译（`connect_unix_socket_native`）。
/// 只裁 FFI、不裁入口，调用方就不会在 Windows 上撞见「标识符未绑定」
/// 那一串指向别处的类型错——issue #94 的 `cli:docker was cancelled`
/// 背后站着的正是这个编译期问题。
#cfg(not(platform="windows"))
#borrow(path, err_out)
extern "C" fn unix_connect_ffi(path : Bytes, err_out : Ref[Int32]) -> @types.Fd = "dive_unix_connect"

///|
/// 关闭一个裸 fd（建连失败之外的收尾路径用）。
#cfg(not(platform="windows"))
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
///
/// 这里**不给整个函数加平台条件**：`http_unix.mbt` 的调用方需要它在两个
/// 平台上都存在（见那里的注释）。平台差异往下压一层，落在
/// `connect_unix_socket_native` 的两个实现上。
pub async fn connect_unix_socket_bytes(
  path : Bytes,
  display : String,
) -> @raw_fd.RawFdStream raise DockerCliError {
  connect_unix_socket_native(path, display)
}

///|
/// 真正建连的那半边，只对 POSIX 编译。
///
/// 为什么不把 `#cfg` 加在 `connect_unix_socket_bytes` 本身：调用方一旦在
/// 被裁掉的分支上写 `catch { err => ... }`，报错会落在「对一个不抛错的表达式
/// catch，`err` 类型对不上」，指向的是调用方而不是真凶。让函数在两个平台
/// 上都存在、只在内部换实现，调用点就不用管平台。
#cfg(not(platform="windows"))
async fn connect_unix_socket_native(
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
/// Windows 的替身：`@raw_fd.RawFdStream` 收的是裸 fd，那边拿到的是不透明
/// `HANDLE`，`AF_UNIX` 也只能靠 1803 之后的 `WSASocket`——本轮不走。
///
/// 报错文案与 C stub 里那句 `EPROTONOSUPPORT` 对齐：两边都说「这台机器
/// 没有 unix socket」，而不是让人去猜 `connect` 为什么失败。
#cfg(platform="windows")
async fn connect_unix_socket_native(
  path : Bytes,
  display : String,
) -> @raw_fd.RawFdStream raise DockerCliError {
  ignore(path)
  raise Backend(display, 93, "connect failed: \{unix_errno_hint(93)}")
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
#cfg(not(platform="windows"))
pub fn close_unix_fd(fd : @types.Fd) -> Unit {
  ignore(unix_close_ffi(fd))
}
