///|
/// Engine 后端：走 unix socket 上的 HTTP，与 `docker` 可执行文件无关。
///
/// 只实现「取到镜像」需要的 4 个端点：`_ping`（探测 + 版本协商）、
/// `GET /images/{name}/json`、`GET /images/{name}/get`、`POST /images/create`。
/// `tcp://` / `ssh://` / context store 明确不做（见 issue #17 非目标）。
pub(all) struct EngineSource {
  uri : UnixUri
  /// 协商到的 API 版本前缀，形如 `/v1.45`；空串表示用无版本路径
  mut api_prefix : String
  timeout_ms : Int32
} derive(Debug)

///|
pub extend EngineSource with @debug.Debug::{to_repr}

///|
/// 新建一个 Engine 后端。API 版本要等第一次 `_ping` 才知道，
/// 因此这里先留空，由 `negotiate` 填。
pub fn EngineSource::new(
  uri : UnixUri,
  timeout_ms~ : Int32 = 0,
) -> EngineSource {
  { uri, api_prefix: "", timeout_ms, }
}

///|
/// `GET /_ping`，拿 `API-Version` 并记下路径前缀。
///
/// 老版本 daemon 可能不回 `API-Version`，这时退回 `v1.24`
/// （`/images/{name}/get` 有史以来的最低版本），保证路径能拼出来。
pub async fn EngineSource::negotiate(
  self : EngineSource,
) -> String raise DockerCliError {
  let response = http_over_unix(
    self.uri.path,
    {
      http_method: "GET",
      path: "/_ping",
      host: self.uri.host,
      headers: [],
      body: b"",
    },
    self.timeout_ms,
  )
  if response.status != 200 {
    raise Backend(self.uri.path, response.status, "GET /_ping failed")
  }
  let version = match response.header("API-Version") {
    Some(value) => value.trim()
    None => "1.24"
  }
  self.api_prefix = "/v\{version}"
  self.api_prefix
}

///|
/// 把相对路径按协商到的版本前缀拼成绝对路径。
fn EngineSource::url(self : EngineSource, path : String) -> String {
  if self.api_prefix.is_empty() {
    path
  } else {
    "\{self.api_prefix}\{path}"
  }
}

///|
impl ImageSource for EngineSource with fn inspect(self, reference) {
  guard_engine_reference(reference)
  if self.api_prefix.is_empty() {
    self.negotiate() |> ignore
  }
  let response = http_over_unix(
    self.uri.path,
    {
      http_method: "GET",
      path: self.url("/images/\{encode_ref(reference)}/json"),
      host: self.uri.host,
      headers: [],
      body: b"",
    },
    self.timeout_ms,
  )
  if response.status != 200 {
    raise Backend(self.uri.path, response.status, error_body(response))
  }
  parse_inspect(CliTool::Docker, response.body, reference)
}

///|
impl ImageSource for EngineSource with fn save(self, reference) {
  guard_engine_reference(reference)
  if self.api_prefix.is_empty() {
    self.negotiate() |> ignore
  }
  // /images/{name}/get 的响应就是 tar 流，直接喂给 P2 的流式解析
  let response = http_over_unix(
    self.uri.path,
    {
      http_method: "GET",
      path: self.url("/images/\{encode_ref(reference)}/get"),
      host: self.uri.host,
      headers: [],
      body: b"",
    },
    self.timeout_ms,
  )
  if response.status != 200 {
    raise Backend(self.uri.path, response.status, error_body(response))
  }
  if response.body.is_empty() {
    raise Backend(
      self.uri.path,
      response.status,
      "save produced an empty archive",
    )
  }
  response.body
}

///|
/// `POST /images/create?fromImage=<name>&tag=<tag>`，把镜像拉到本地。
///
/// 响应是 `application/vnd.docker.raw-stream`：一行一个 JSON 事件，
/// 形如 `{"status":"Pulling fs layer","id":"0a3621ec1dd4"}`，
/// 出错时是 `{"errorDetail":{"message":"..."}}`。
/// 这里**真解析**这些事件：HTTP 200 不代表拉成功——
/// daemon 会在流里回 200 之后再吐 `errorDetail`（镜像不存在、认证失败、
/// registry 不可达都走这条路）。只看状态码会把失败当成成功。
///
/// 进度本身不打日志：这是包一层的能力，输出归调用方管。
impl ImageSource for EngineSource with fn pull(self, reference) {
  guard_engine_reference(reference)
  if self.api_prefix.is_empty() {
    self.negotiate() |> ignore
  }
  let (name, tag) = split_reference(reference)
  let query = "fromImage=\{encode_ref(name)}&tag=\{encode_ref(tag)}"
  let response = http_over_unix(
    self.uri.path,
    {
      http_method: "POST",
      path: self.url("/images/create?\{query}"),
      host: self.uri.host,
      headers: [],
      body: b"",
    },
    self.timeout_ms,
  )
  if response.status != 200 {
    raise Backend(self.uri.path, response.status, error_body(response))
  }
  match pull_error_of_stream(bytes_to_string(response.body)) {
    Some(message) => raise Backend(self.uri.path, response.status, message)
    None => ()
  }
}

///|
/// 从 pull 的 raw-stream 里挖出第一条 `error` / `errorDetail.message`。
///
/// 逐行解析、坏行直接跳过：daemon 的进度行与错误行混在一条流里，
/// 一条解析不了的噪声不该让整个判定失败（失败判定要保守，
/// 但「流里有明确错误」这件事必须被抓到）。
pub fn pull_error_of_stream(stream : String) -> String? {
  for line in stream.split("\n") {
    let text = line.trim()
    if !text.has_prefix("{") {
      continue
    }
    let parsed = @json.parse(text) catch { _ => continue }
    match pull_error_of_event(parsed) {
      Some(message) => return Some(message)
      None => ()
    }
  }
  None
}

///|
/// 单个事件对象里的错误字段。优先 `errorDetail.message`（新版 daemon），
/// 退回 `error`（老版 daemon 与部分代理）。
fn pull_error_of_event(event : Json) -> String? {
  let fields = match event {
    Object(fields) => fields
    _ => return None
  }
  match fields.get("errorDetail") {
    Some(Object(detail)) =>
      match detail.get("message") {
        Some(String(message)) => return Some(message)
        _ => ()
      }
    _ => ()
  }
  match fields.get("error") {
    Some(String(message)) => Some(message)
    _ => None
  }
}

///|
/// 镜像名里的 `/` 在路径里要保义，`:tag` 的 `:` 也是。
/// Engine API 接受 URL 编码后的名字，这里按 RFC 3986 保留 `/` 与 `:`。
fn encode_ref(reference : String) -> String {
  let builder = StringBuilder()
  for index = 0; index < reference.length(); index = index + 1 {
    let code = reference[index].to_int()
    if is_unreserved(code) {
      builder.write_char(Int32::unsafe_to_char(code))
    } else {
      builder.write_char('%')
      builder.write_char(hex_digit((code >> 4) & 0xF))
      builder.write_char(hex_digit(code & 0xF))
    }
  }
  builder.to_string()
}

///|
/// RFC 3986 `unreserved` 加上路径分隔符与端口冒号：这些字符在 Engine API
/// 的路径段里是安全的，编码掉反而会让 daemon 认不出镜像名。
fn is_unreserved(code : Int32) -> Bool {
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) ||
  code == '-'.to_int() ||
  code == '.'.to_int() ||
  code == '_'.to_int() ||
  code == '~'.to_int() ||
  code == '/'.to_int() ||
  code == ':'.to_int()
}

///|
fn hex_digit(value : Int32) -> Char {
  if value < 10 {
    Int32::unsafe_to_char(value + '0'.to_int())
  } else {
    Int32::unsafe_to_char(value - 10 + 'a'.to_int())
  }
}

///|
/// `nginx` → `("nginx", "latest")`；`nginx:1.25` → `("nginx", "1.25")`。
/// 末尾带 digest 的 `name@sha256:...` 不做拆分，整体当 name 传给 Engine。
fn split_reference(reference : String) -> (String, String) {
  if reference.contains("@") {
    return (reference, "latest")
  }
  match reference.rev_find(":") {
    Some(index) =>
      // registry 带端口（host:5000/img）时最后一个冒号不是 tag 分隔符
      if reference[index + 1:].contains("/") {
        (reference, "latest")
      } else {
        (reference[:index].to_owned(), reference[index + 1:].to_owned())
      }
    None => (reference, "latest")
  }
}

///|
/// Engine 的镜像名不能为空。
fn guard_engine_reference(reference : String) -> Unit raise DockerCliError {
  if reference.trim().is_empty() {
    raise InvalidReference("image reference is empty")
  }
}

///|
/// 错误响应体通常是 `{"message": "..."}`，拿不到就原样转成文本。
fn error_body(response : HttpResponse) -> String {
  let text = bytes_to_string(response.body)
  let parsed = @json.parse(text) catch { _ => return text.trim().to_owned() }
  match parsed {
    Object(fields) =>
      match fields.get("message") {
        Some(String(message)) => message
        _ => text.trim().to_owned()
      }
    _ => text.trim().to_owned()
  }
}

///|
pub extend EngineSource with ImageSource::{inspect, save, pull}

///|
/// 测试入口：暴露版本前缀拼接。
pub fn EngineSource::api_path(self : EngineSource, path : String) -> String {
  self.url(path)
}

///|
/// 测试入口：直接设定协商到的 API 版本，免去起 daemon。
pub fn EngineSource::set_api_version(
  self : EngineSource,
  version : String,
) -> Unit {
  self.api_prefix = "/v\{version}"
}

///|
/// 测试入口：暴露引用编码。
pub fn encode_ref_for_test(reference : String) -> String {
  encode_ref(reference)
}

///|
/// 测试入口：暴露 `name:tag` 拆分。
pub fn split_reference_for_test(reference : String) -> (String, String) {
  split_reference(reference)
}

///|
/// 测试入口：暴露错误响应体提取。
pub fn error_body_for_test(response : HttpResponse) -> String {
  error_body(response)
}
