///|
/// 裸 unix socket 上的最小 HTTP/1.1 客户端。
///
/// 只做 Engine API 需要的那几条：发一个请求头 + 可选 body，
/// 读状态行、头部、按 `Content-Length` 或 `Transfer-Encoding: chunked`
/// 收 body。不做 keep-alive 复用、不做重定向、不做 TLS。
///
/// 之所以不用 `moonbitlang/async/http`：它面向 `http(s)://` URL，
/// 走 DNS + TCP + TLS，没有 unix socket 的入口。
/// 连接由 `connect_unix_socket` 提供（native 上是 `@raw_fd.RawFdStream`），
/// 这里只做 HTTP/1.1 报文层的组装与解析。
pub(all) struct HttpResponse {
  status : Int32
  headers : Array[(String, String)]
  body : Bytes
} derive(Eq, Debug)

///|
pub extend HttpResponse with Eq::{equal, not_equal}

///|
pub extend HttpResponse with @debug.Debug::{to_repr}

///|
/// 头字段查找，键按 ASCII 大小写不敏感比对。
pub fn HttpResponse::header(self : HttpResponse, name : String) -> String? {
  let wanted = name.to_lower()
  for entry in self.headers {
    let (key, value) = entry
    if key.to_lower() == wanted {
      return Some(value)
    }
  }
  None
}

///|
/// 单次请求的输入。
pub(all) struct HttpRequest {
  http_method : String
  /// 例如 `/v1.45/images/nginx:latest/get`，必须以 `/` 开头
  path : String
  host : String
  headers : Array[(String, String)]
  body : Bytes
} derive(Eq, Debug)

///|
pub extend HttpRequest with Eq::{equal, not_equal}

///|
pub extend HttpRequest with @debug.Debug::{to_repr}

///|
/// 往 unix socket 发一个请求并读完整响应。
pub async fn http_over_unix(
  socket_path : String,
  request : HttpRequest,
  timeout_ms : Int32,
) -> HttpResponse raise DockerCliError {
  let work = () => {
    let connection = connect_unix_socket(socket_path) catch {
      err => raise connect_error(socket_path, err)
    }
    defer connection.close()
    let head = build_head(request)
    @io.Writer::write(connection, head) catch {
      err => raise Backend(socket_path, -1, "write failed: \{err}")
    }
    if request.body.length() > 0 {
      @io.Writer::write(connection, request.body) catch {
        err => raise Backend(socket_path, -1, "write body failed: \{err}")
      }
    }
    read_response(connection, socket_path)
  }
  if timeout_ms > 0 {
    // 超时不走 `catch`：`moonbitlang/async` 的取消**不是**一个可捕获的错误
    // （见 `with_timeout_opt` 的注释——`catch` 抓不到取消），超时只会让
    // `with_timeout_opt` 返回 `None`。所以这里的 `catch` 只接 `work()` 自己
    // 抛的错，原样带出去即可。
    //
    // 之前是 `catch { err => raise Backend(socket_path, -1, err.to_string()) }`：
    // 把一个已经成型的 `Backend` 渲染成字符串再塞回 `Backend`，
    // `Show` 再渲染一次，用户看到的是
    // 「/var/run/docker.sock failed: /var/run/docker.sock failed: connect failed: errno 2」。
    // 一次失败被描述两遍，排查的人只能猜。
    let result = @async.with_timeout_opt(timeout_ms, () => work()) catch {
      err => raise preserve(err)
    }
    match result {
      Some(response) => response
      None => raise Cancelled(socket_path)
    }
  } else {
    work()
  }
}

///|
/// `catch` 拿到的是 `Error`，这里把它还原成 `DockerCliError`。
///
/// 能原样还原的直接还原（保住 `name` / `code` 这些结构化字段，
/// `Show` 只渲染一次）；认不出来的才折成 `Backend`。
fn preserve(err : Error) -> DockerCliError {
  match err {
    DockerCliError::NoBackend(detail) => NoBackend(detail)
    DockerCliError::Backend(name, code, detail) => Backend(name, code, detail)
    DockerCliError::ExecutableNotFound(name) => ExecutableNotFound(name)
    DockerCliError::Cancelled(name) => Cancelled(name)
    DockerCliError::Archive(detail) => Archive(detail)
    DockerCliError::InvalidReference(detail) => InvalidReference(detail)
    DockerCliError::ImageNotFound(reference) => ImageNotFound(reference)
    _ => Backend("http", -1, err.to_string())
  }
}

///|
/// 把建连失败收成 `Backend`：unix socket 上「连不上」
/// 通常意味着 daemon 没起，错误信息要能让用户看懂。
///
/// 已经是 `Backend` 的就不再包一层：`Show` 会按 `name` 渲染成
/// 「<name> failed: <detail>」，再包一次就是「<name> failed: <name> failed: ...」。
fn connect_error(path : String, err : DockerCliError) -> DockerCliError {
  match err {
    Backend(_, _, _) => err
    _ => Backend(path, -1, err.to_string())
  }
}

///|
/// 组装请求头。`Host` 是 HTTP/1.1 的必填项；`Connection: close`
/// 让我们不必实现 keep-alive 复用，读完 body 直接关。
fn build_head(request : HttpRequest) -> String {
  let builder = StringBuilder()
  builder.write_string("\{request.http_method} \{request.path} HTTP/1.1\r\n")
  builder.write_string("Host: \{request.host}\r\n")
  builder.write_string("Connection: close\r\n")
  builder.write_string("Accept: application/json\r\n")
  for entry in request.headers {
    let (key, value) = entry
    builder.write_string("\{key}: \{value}\r\n")
  }
  if request.body.length() > 0 {
    builder.write_string("Content-Length: \{request.body.length()}\r\n")
    builder.write_string("Content-Type: application/json\r\n")
  }
  builder.write_string("\r\n")
  builder.to_string()
}

///|
/// 读状态行 + 头部；head 与 body 的边界由 `read_until` 找到。
async fn read_response(
  connection : @raw_fd.RawFdStream,
  context_ : String,
) -> HttpResponse raise DockerCliError {
  let status_line = connection.read_until("\r\n") catch {
    err => raise Backend(context_, -1, "read status line failed: \{err}")
  }
  let status_line = match status_line {
    Some(line) => line
    None => raise Backend(context_, -1, "connection closed before status line")
  }
  let status = parse_status(status_line)
  let headers = []
  while true {
    let line = connection.read_until("\r\n") catch {
      err => raise Backend(context_, -1, "read header failed: \{err}")
    }
    let line = match line {
      Some(line) => line
      None => raise Backend(context_, -1, "connection closed mid-headers")
    }
    if line.is_empty() {
      break
    }
    headers.push(split_header(line))
  }
  let body = read_body(connection, headers, context_)
  { status, headers, body, }
}

///|
/// `HTTP/1.1 200 OK` → 200。非 HTTP 响应（比如把普通文件当 socket 打开的误判）
/// 一并报成 `Backend`，信息里带上原始首行。
fn parse_status(line : String) -> Int32 raise DockerCliError {
  let parts = line.split(" ").collect()
  guard parts.length() >= 2 else {
    raise Backend("http", -1, "malformed status line: \{line}")
  }
  let code = parts[1]
  match parse_decimal(code) {
    Some(value) => value
    None => raise Backend("http", -1, "malformed status line: \{line}")
  }
}

///|
fn split_header(line : String) -> (String, String) {
  match line.find(":") {
    Some(index) =>
      (line[:index].trim().to_owned(), line[index + 1:].trim().to_owned())
    None => (line.trim().to_owned(), "")
  }
}

///|
/// 收 body。`Transfer-Encoding: chunked` 优先于 `Content-Length`
/// （RFC 7230：chunked 在场时忽略 Content-Length），两个都没有就当空 body。
async fn read_body(
  connection : @raw_fd.RawFdStream,
  headers : Array[(String, String)],
  context_ : String,
) -> Bytes raise DockerCliError {
  let mut chunked = false
  let mut length : Int32? = None
  for entry in headers {
    let (key, value) = entry
    let lower = key.to_lower()
    if lower == "transfer-encoding" && value.to_lower().contains("chunked") {
      chunked = true
    } else if lower == "content-length" {
      length = parse_decimal(value.trim())
    }
  }
  if chunked {
    read_chunked(connection, context_)
  } else {
    match length {
      Some(size) => read_exact(connection, size, context_)
      None => b""
    }
  }
}

///|
async fn read_exact(
  connection : @raw_fd.RawFdStream,
  size : Int32,
  context_ : String,
) -> Bytes raise DockerCliError {
  if size == 0 {
    return b""
  }
  connection.read_exactly(size) catch {
    err => raise Backend(context_, -1, "read body failed: \{err}")
  }
}

///|
/// chunked 传输：`<hex-size>\r\n<data>\r\n` 重复，0 长度块收尾（后面可能还有 trailer）。
///
/// `docker save` 的归档就是这个形式，也是「大镜像不落内存」要盯的地方：
/// 这里的实现仍然把整段拼进内存，流式版本与 Engine 后端的完整能力一并留给后续。
async fn read_chunked(
  connection : @raw_fd.RawFdStream,
  context_ : String,
) -> Bytes raise DockerCliError {
  let buffer = @buffer.Buffer()
  while true {
    let size_line = connection.read_until("\r\n") catch {
      err => raise Backend(context_, -1, "read chunk size failed: \{err}")
    }
    let size_line = match size_line {
      Some(line) => line
      None => raise Backend(context_, -1, "connection closed mid-chunk")
    }
    let size = parse_chunk_size(size_line)
    if size == 0 {
      // 收尾：读掉 trailer 段落（空行结束）
      while true {
        let trailer = connection.read_until("\r\n") catch { _ => break }
        match trailer {
          Some(line) if line.is_empty() => break
          Some(_) => continue
          None => break
        }
      }
      break
    }
    let chunk = read_exact(connection, size, context_)
    buffer.write_bytes(chunk)
    // 每个 chunk 后面跟一个 CRLF
    ignore(
      connection.read_exactly(2) catch {
        err =>
          raise Backend(context_, -1, "read chunk terminator failed: \{err}")
      },
    )
  }
  buffer.to_bytes()
}

///|
/// chunk 长度是十六进制，可能带 `;ext=...` 后缀。
fn parse_chunk_size(line : String) -> Int32 raise DockerCliError {
  let raw = match line.find(";") {
    Some(index) => line[:index]
    None => line
  }
  let text = raw.trim()
  match parse_hex(text) {
    Some(size) => size
    None => raise Backend("http", -1, "malformed chunk size: \{line}")
  }
}

///|
/// 十进制解析。核心库里没有 `Int::from_string` 的稳定入口，
/// 这里按需要自己收口：只认 ASCII 数字，非法即 `None`。
fn parse_decimal(text : StringView) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for index = 0; index < text.length(); index = index + 1 {
    let code = text[index].to_int()
    if code < '0'.to_int() || code > '9'.to_int() {
      return None
    }
    value = value * 10 + (code - '0'.to_int())
  }
  Some(value)
}

///|
/// 十六进制解析（chunk 长度用），兼容大小写，忽略前导 `0x`。
fn parse_hex(text : StringView) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut start = 0
  if text.length() > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') {
    start = 2
  }
  let mut value = 0
  for index = start; index < text.length(); index = index + 1 {
    let code = text[index].to_int()
    let digit = if code >= '0'.to_int() && code <= '9'.to_int() {
      code - '0'.to_int()
    } else if code >= 'a'.to_int() && code <= 'f'.to_int() {
      code - 'a'.to_int() + 10
    } else if code >= 'A'.to_int() && code <= 'F'.to_int() {
      code - 'A'.to_int() + 10
    } else {
      return None
    }
    value = value * 16 + digit
  }
  Some(value)
}

///|
/// 测试入口：暴露请求头组装。
pub fn build_head_for_test(request : HttpRequest) -> String {
  build_head(request)
}

///|
/// 测试入口：暴露状态行解析。
pub fn parse_status_for_test(line : String) -> Int32 raise DockerCliError {
  parse_status(line)
}

///|
/// 测试入口：暴露 chunk 长度解析。
pub fn parse_chunk_size_for_test(line : String) -> Int32 raise DockerCliError {
  parse_chunk_size(line)
}
