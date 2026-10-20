///|
/// 与一个 registry 说话的最小 HTTP 客户端。
///
/// 只做拉取需要的那几个动作：`GET` 一个路径拿「状态 + 头 + 整段 body」。
/// 不抽 REST 框架：registry 的 manifest / blob 端点都是幂等的 GET，
/// 一个方法够用，多写只会多出没测过的分支。
pub struct RegistryClient {
  /// `https://host` 或 `http://host`（`--insecure`）
  base : String
  mut token : String?
  client : @http.Client
}

///|
pub impl Show for RegistryClient with fn to_string(self) {
  self.base
}

///|
pub extend RegistryClient with Show::{to_string, output}

///|
/// 正文还没读的应答：一个 HTTP 客户端 + 它的长度上限。
///
/// 做成不透明字段是因为「读多少、什么时候报进度」只有 `read_body` 说了算；
/// 让调用方直接摸客户端，迟早有人写出「读到一半又发下一个请求」这种代码。
struct ReplySource {
  client : @http.Client
  /// `content-length`（没有就是 `None`：chunked 或重定向后不给长度）
  length : Int32?
}

///|
/// 一次 `GET` 的原始结果。
///
/// `body` 一律是「还没读的正文」的占位：内容靠 `HttpReply::read_body` 取。
/// 这里不留 `Bytes` 字段，是因为一个 700MB 的层真的会被读成 700MB 的内存，
/// 而读的时候还要能一段一段报进度（issue #97）。
pub(all) struct HttpReply {
  status : Int32
  headers : Map[String, String]
  /// 已经读出来的字节（`RegistryClient::get` 返回时为空，见 `read_body`）
  body : Bytes
  /// 真正的读取入口；手工构造的应答（测试、重定向解析）为 `None`
  source : ReplySource?
}

///|
pub impl Eq for HttpReply with fn equal(self, other) {
  // 连接对象不可比：同一个「状态 + 头 + 已读字节」就是同一条应答
  self.status == other.status &&
  self.headers == other.headers &&
  self.body == other.body
}

///|
pub extend HttpReply with Eq::{equal, not_equal}

///|
pub impl @debug.Debug for HttpReply with fn to_repr(self) {
  // `source` 是一个还开着的连接，打出来对排查没帮助
  @debug.Repr::ctor("HttpReply", [
    (
      None,
      @debug.Repr::record(
        Map([
          ("status", @debug.Repr::integer(self.status.to_string())),
          ("body", @debug.Repr::integer(self.body.length().to_string())),
        ]),
      ),
    ),
  ])
}

///|
pub extend HttpReply with @debug.Debug::{to_repr}

///|
/// 取一个头（大小写不敏感）。
pub fn HttpReply::header(self : HttpReply, name : String) -> String? {
  self.headers.get(name.to_lower().to_string())
}

///|
/// 连上一个 registry。
///
/// `insecure` 只改协议（`http://`）与证书校验两件事，**不改**端口推导：
/// 自建 registry 常跑在 5000，显式写 `host:5000` 就好，不给猜。
pub async fn RegistryClient::connect(
  host : String,
  insecure~ : Bool = false,
  token~ : String? = None,
) -> RegistryClient {
  let scheme = if insecure { "http" } else { "https" }
  let base = "\{scheme}://\{host}"
  let client = @http.Client(
    base,
    trust=if insecure { @tls.NoVerification } else { @tls.SystemRoot },
  )
  { base, token, client, }
}

///|
pub fn RegistryClient::close(self : RegistryClient) -> Unit {
  self.client.close()
}

///|
/// 发一个 GET，**只收响应头**，正文留给 `HttpReply::read_body`。
///
/// 为什么不在这里一次读完：镜像的一层就是几百 MB，`read_all` 会把整层攒在
/// 内存里，而调用方其实只想「边下边写盘、顺便报个进度」（issue #97）。
///
/// 失败折成 `Network`：连不上、TLS 握手失败都在这条路上。
/// 状态码不在这里判——401 / 404 都是有意义的答复，交给调用方。
pub async fn RegistryClient::get(
  self : RegistryClient,
  path : String,
  headers~ : Map[String, String] = Map([]),
) -> HttpReply raise RegistryError {
  let merged = http_headers(headers, self.token)
  let response = self.client.get(path, extra_headers=merged) catch {
    err => raise Network("\{self.base}\{path}: \{err}")
  }
  let fields : Map[String, String] = Map([])
  for name, value in response.headers {
    fields.set(name.to_string().to_lower().to_string(), value)
  }
  let length = match fields.get("content-length") {
    Some(text) =>
      match parse_decimal_length(text) {
        Some(value) if value >= 0 => Some(value)
        _ => None
      }
    None => None
  }
  {
    status: response.code,
    headers: fields,
    body: b"",
    source: Some({ client: self.client, length, }),
  }
}

///|
/// 把这个应答的正文读干净（不带进度回调）。
pub async fn HttpReply::read_body(
  self : HttpReply,
) -> Bytes raise RegistryError {
  self.read_body_with(on_progress?=None)
}

///|
/// 把正文读出来；`on_progress` 每积够 `PROGRESS_STEP` 报一次 `(已读, 总长?)`。
///
/// 读不了第二次：正文与「下一个请求」共用同一条连接，二次读取读到的是下一条应答。
/// 所以拿到 `Bytes` 后要复用就自己留一份，别指望这里能倒带。
pub async fn HttpReply::read_body_with(
  self : HttpReply,
  on_progress? : (Int64, Int64?) -> Unit,
  on_tick? : () -> Unit noraise,
) -> Bytes raise RegistryError {
  match self.source {
    None => self.body
    Some(source) => {
      let total = match source.length {
        Some(length) => Some(length.to_int64())
        None => None
      }
      read_chunks(source.client, total, on_progress?, on_tick?) catch {
        err => raise Network("reading the response body: \{err}")
      }
    }
  }
}

///|
/// 一段一段把连接上的正文读进来，最后拼成一整块。
///
/// 拼的时候按 `chunk_size` 预分配 + 尾部裁剪：`ArrayBuilder` 风格的增长
/// 在 700MB 上既慢又会短暂占用两倍内存，而这里的长度其实一开始就知道
/// （要么有 `content-length`，要么只能先记 chunk 列表）。
async fn read_chunks(
  client : @http.Client,
  length : Int64?,
  on_progress? : (Int64, Int64?) -> Unit,
  on_tick? : () -> Unit noraise,
) -> Bytes raise RegistryError {
  let chunk_size = 65536
  let chunks : Array[Bytes] = []
  let mut received : Int64 = 0
  let mut reported : Int64 = 0
  while true {
    let chunk = client.read_some(max_len=chunk_size) catch {
      err => raise Network("reading the response body: \{err}")
    }
    let data = match chunk {
      None => break
      Some(data) => data
    }
    received = received + data.length().to_int64()
    chunks.push(data)
    match on_progress {
      Some(callback) =>
        if received - reported >= progress_step {
          reported = received
          callback(received, length)
          // 进度报完就写终端：回调本身是同步的，写不了 stderr；
          // 这里是 async，正好把「攒下的那一格」送出去
          match on_tick {
            Some(tick) => tick()
            None => ()
          }
        }
      None => ()
    }
  }
  match on_progress {
    Some(callback) => {
      callback(received, length)
      match on_tick {
        Some(tick) => tick()
        None => ()
      }
    }
    None => ()
  }
  if received > 2147483647 {
    // 一次读进内存的东西不该超过 `Int`：真超了说明用法本来就错了
    raise Network(
      "response body is \{received} bytes, too large to hold in memory",
    )
  }
  let total = received.to_int()
  let result = FixedArray::make(total, b'\x00')
  let mut offset = 0
  for chunk in chunks {
    let len = chunk.length()
    result.blit_from_bytesview(offset, chunk[:])
    offset = offset + len
  }
  result.unsafe_reinterpret_as_bytes()
}

///|
/// 我们的头（普通 Map）转成 HTTP 客户端要的大小写不敏感 Map，
/// 顺手把当前 token 挂上去——调用方不必每次自己拼 `Authorization`。
fn http_headers(
  headers : Map[String, String],
  token : String?,
) -> Map[@http.CaseInsensitiveString, String] {
  let merged : Map[@http.CaseInsensitiveString, String] = Map([])
  for name, value in headers {
    merged.set(@http.CaseInsensitiveString(name), value)
  }
  match token {
    Some(token) =>
      merged.set(
        @http.CaseInsensitiveString("authorization"),
        "Bearer \{token}",
      )
    None => ()
  }
  merged
}

///|
/// 记下换到的 token，后续请求自动带上。
pub fn RegistryClient::set_token(self : RegistryClient, token : String) -> Unit {
  self.token = Some(token)
}

///|
/// 当前 token（调试用；不要打给用户看）。
pub fn RegistryClient::has_token(self : RegistryClient) -> Bool {
  self.token is Some(_)
}

///|
/// 响应是不是重定向。registry 的 blob 端点几乎总会 307 到 CDN，
/// 客户端库不替我们跟，得自己跟。
pub fn HttpReply::is_redirect(self : HttpReply) -> Bool {
  self.status == 301 ||
  self.status == 302 ||
  self.status == 303 ||
  self.status == 307 ||
  self.status == 308
}

///|
/// 拿一个重定向的绝对地址：`Location` 可能是相对路径，按 `base` 补全。
///
/// registry 的 blob 重定向基本都给绝对地址，但相对路径这一支仍然要处理——
/// 不处理它不会「少见地出错」，而是**直接把 307 当失败**，症状还很难看出来。
///
/// 做成自由函数（而不是 `RegistryClient` 的方法）是因为它与连接状态无关：
/// 建客户端要真的拨号，一个「解析 URL」的纯逻辑不该逼调用方先连上。
pub fn resolve_location(
  base : String,
  location : String,
) -> (String, String) raise RegistryError {
  let target : String = location.trim().to_owned()
  if target.has_prefix("https://") || target.has_prefix("http://") {
    return split_url(target)
  }
  // host 相对（`/v2/...`）：只有这一种是 registry 会发的形状
  if target.has_prefix("/") {
    return (base, target)
  }
  raise Network(
    "the registry redirected to a relative location this client cannot resolve: \{target}",
  )
}

///|
/// `content-length` 这种纯十进制长度；解析不出来就当没有（chunked 也走这条路）。
fn parse_decimal_length(text : String) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for unit in text {
    let code = unit.to_int()
    if code < '0'.to_int() || code > '9'.to_int() {
      return None
    }
    value = value * 10 + (code - '0'.to_int())
  }
  Some(value)
}
