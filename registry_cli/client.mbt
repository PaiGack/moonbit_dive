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
/// 一次 `GET` 的原始结果。
pub(all) struct HttpReply {
  status : Int32
  headers : Map[String, String]
  body : Bytes
} derive(Eq, Debug)

///|
pub extend HttpReply with Eq::{equal, not_equal}

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
/// 发一个 GET，把 body 整段读回来。
///
/// 失败折成 `Network`：连不上、TLS 握手失败、读一半断了都在这条路上。
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
  let body = self.client.read_all() catch {
    err => raise Network("\{self.base}\{path}: \{err}")
  }
  let fields : Map[String, String] = Map([])
  for name, value in response.headers {
    fields.set(name.to_string().to_lower().to_string(), value)
  }
  { status: response.code, headers: fields, body: body.binary(), }
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
