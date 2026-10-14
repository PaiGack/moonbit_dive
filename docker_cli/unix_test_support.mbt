///|
/// 测试专用的 unix socket 服务端。
///
/// `moonbitlang/async/socket` 只有 TCP / UDP 绑定，没有 AF_UNIX 的
/// listen / accept，Engine 后端的传输层因此起不了 fake daemon。
/// 这里用一层薄 FFI（`unix_socket_test_stub.c`）补上建监听与 accept，
/// 客户端连接复用生产侧的 `connect_unix_socket`，
/// 连接 fd 一律包成 `@raw_fd.RawFdStream` 走事件循环收发字节。
///
/// listen / accept 只为测试服务，不进成品包的公开 API。
///
/// 只面向 POSIX：Windows 上没有 `AF_UNIX` 的稳定绑定，测试会显式跳过。
#cfg(not(platform="windows"))
#borrow(path)
extern "C" fn unix_test_listen_ffi(path : Bytes) -> Int32 = "dive_unix_test_listen"

///|
#cfg(not(platform="windows"))
extern "C" fn unix_test_accept_ffi(listen_fd : Int32) -> Int32 = "dive_unix_test_accept"

///|
/// 监听者的连接被 accept 之前，监听 socket 会返回 `-EAGAIN`。
/// accept 要轮询等它就绪：fd 是非阻塞的，等不到就 sleep 一下再看。
#cfg(not(platform="windows"))
const ACCEPT_POLL_INTERVAL_MS : Int32 = 2

///|
/// accept 的总等待上限（毫秒）。测试里连的是自己刚起的服务端，
/// 正常情况下第一次轮询就能拿到；超时说明用例本身有问题，宁可失败也别挂住。
#cfg(not(platform="windows"))
const ACCEPT_TIMEOUT_MS : Int32 = 5000

///|
/// 测试用的 unix socket 服务端。
///
/// 起一个监听 socket 之后，可以按顺序 accept 多条连接，
/// 每条连接是一个 `@raw_fd.RawFdStream`，能收发字节、也能当
/// `@io.Reader` / `@io.Writer` 用。
#cfg(not(platform="windows"))
pub struct UnixSocketServer {
  path : String
  listen_fd : Int32
  dir : String
}

///|
/// 在临时目录里起一个监听 socket，返回服务端与地址。
#cfg(not(platform="windows"))
pub async fn UnixSocketServer::start() -> UnixSocketServer raise DockerCliError {
  let dir = @fs.tmpdir(prefix="dive-unix-") catch {
    err => raise Backend("tmpdir", -1, "cannot create temp dir: \{err}")
  }
  // 路径要短：`sun_path` 只有 108 字节，tmpdir 前缀长了会被截断
  UnixSocketServer::start_at("\{dir}/s.sock")
}

///|
/// 在指定路径上起监听 socket。测试要断言「路径写进 URI 时是什么样」时用这个。
#cfg(not(platform="windows"))
pub fn UnixSocketServer::start_at(
  path : String,
) -> UnixSocketServer raise DockerCliError {
  let listen_fd = unix_test_listen_ffi(@utf8.encode(path))
  if listen_fd < 0 {
    raise Backend(path, -1, "cannot listen on unix socket: errno \{-listen_fd}")
  }
  { path, listen_fd, dir: parent_of(path), }
}

///|
/// 等一条进来的连接，把它包成可收发字节的流。
///
/// 会轮询到超时为止：测试里服务端和客户端在同一个任务组里，
/// 客户端的 connect 晚一点到是常态。
#cfg(not(platform="windows"))
pub async fn UnixSocketServer::accept(
  self : UnixSocketServer,
) -> @raw_fd.RawFdStream raise DockerCliError {
  let mut waited = 0
  while waited <= ACCEPT_TIMEOUT_MS {
    let fd = unix_test_accept_ffi(self.listen_fd)
    if fd >= 0 {
      let stream = @raw_fd.RawFdStream(fd) catch {
        err => raise Backend(self.path, -1, "cannot wrap accepted fd: \{err}")
      }
      return stream
    }
    @async.sleep(ACCEPT_POLL_INTERVAL_MS)
    waited = waited + ACCEPT_POLL_INTERVAL_MS
  }
  raise Backend(self.path, -1, "accept timed out after \{ACCEPT_TIMEOUT_MS}ms")
}

///|
/// 关掉监听 socket 并清掉临时目录。
#cfg(not(platform="windows"))
pub async fn UnixSocketServer::close(self : UnixSocketServer) -> Unit {
  close_unix_fd(self.listen_fd)
  @fs.rmdir(self.dir, recursive=true) catch {
    _ => ()
  }
}

///|
/// 测试客户端：连到这个服务端，走的就是生产侧的连接入口。
#cfg(not(platform="windows"))
pub async fn UnixSocketServer::connect(
  self : UnixSocketServer,
) -> @raw_fd.RawFdStream raise DockerCliError {
  connect_unix_socket(self.path)
}

///|
/// 读到「缓冲里出现 delimiter」为止，返回含 delimiter 的字节。
/// 用于服务端读完一个请求头再回响应。
#cfg(not(platform="windows"))
pub async fn read_until(
  stream : @raw_fd.RawFdStream,
  delimiter : Bytes,
) -> Bytes raise DockerCliError {
  guard delimiter.length() > 0 else {
    raise Backend("unix stream", -1, "empty delimiter")
  }
  let buffer = @buffer.Buffer()
  let chunk = FixedArray::make(4096, b'\x00')
  while true {
    if contains(buffer.to_bytes(), delimiter) {
      break
    }
    let n = stream.read(chunk) catch {
      err => raise Backend("unix stream", -1, "read failed: \{err}")
    }
    if n == 0 {
      break
    }
    buffer.write_bytes(chunk.unsafe_reinterpret_as_bytes()[:n])
  }
  buffer.to_bytes()
}

///|
/// 子串查找，`Bytes` 版。
#cfg(not(platform="windows"))
fn contains(haystack : Bytes, needle : Bytes) -> Bool {
  let h = haystack.length()
  let n = needle.length()
  if n == 0 || n > h {
    return false
  }
  for start = 0; start <= h - n; start = start + 1 {
    let mut matched = true
    for offset = 0; offset < n; offset = offset + 1 {
      if haystack[start + offset] != needle[offset] {
        matched = false
        break
      }
    }
    if matched {
      return true
    }
  }
  false
}

///|
/// 一个目录路径的父目录。
#cfg(not(platform="windows"))
fn parent_of(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => path[:index].to_owned()
    None => "."
  }
}
