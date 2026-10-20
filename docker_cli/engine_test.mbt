///|
/// Engine 后端的请求头组装：方法、路径、Host、Connection 都必须齐。
/// HTTP/1.1 少 Host 会被 daemon 直接拒掉。
async test "engine request head has the required lines" {
  let head = @docker_cli.build_head_for_test(
    (
      {
        http_method: "GET",
        path: "/v1.45/images/nginx:latest/json",
        host: "localhost",
        headers: [],
        body: b"",
      } : @docker_cli.HttpRequest),
  )
  assert_true(
    head.has_prefix("GET /v1.45/images/nginx:latest/json HTTP/1.1\r\n"),
  )
  assert_true(head.contains("Host: localhost\r\n"))
  assert_true(head.contains("Connection: close\r\n"))
  assert_true(head.has_suffix("\r\n\r\n"))
  // 无 body 时不该出现 Content-Length
  assert_true(!head.contains("Content-Length"))
}

///|
/// 有 body 的 POST 必须带 Content-Length，否则 daemon 会一直等。
async test "engine request head declares a body" {
  let head = @docker_cli.build_head_for_test(
    (
      {
        http_method: "POST",
        path: "/v1.45/images/create?fromImage=nginx&tag=latest",
        host: "localhost",
        headers: [],
        body: b"{\"a\":1}",
      } : @docker_cli.HttpRequest),
  )
  assert_true(head.contains("Content-Length: 7\r\n"))
  assert_true(head.contains("Content-Type: application/json\r\n"))
}

///|
/// 状态行 → 状态码。
async test "engine parses the status line" {
  assert_eq(@docker_cli.parse_status_for_test("HTTP/1.1 200 OK"), 200)
  assert_eq(@docker_cli.parse_status_for_test("HTTP/1.1 404 Not Found"), 404)
  let error = try {
    @docker_cli.parse_status_for_test("garbage") |> ignore
    fail("should reject")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("malformed status line"))
}

///|
/// chunked 的块大小是十六进制，可能带扩展后缀。
async test "engine parses chunk sizes" {
  assert_eq(@docker_cli.parse_chunk_size_for_test("1f"), 31)
  assert_eq(@docker_cli.parse_chunk_size_for_test("1F"), 31)
  assert_eq(@docker_cli.parse_chunk_size_for_test("8;ext=foo"), 8)
  let error = try {
    @docker_cli.parse_chunk_size_for_test("zz") |> ignore
    fail("should reject")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("malformed chunk size"))
}

///|
/// 头字段查找大小写不敏感；Engine 的响应头大小写并不固定。
async test "engine headers are case insensitive" {
  let response : @docker_cli.HttpResponse = {
    status: 200,
    headers: [("API-Version", "1.45"), ("Content-Type", "application/json")],
    body: b"",
  }
  assert_eq(
    @docker_cli.HttpResponse::header(response, "api-version"),
    Some("1.45"),
  )
  assert_eq(
    @docker_cli.HttpResponse::header(response, "API-VERSION"),
    Some("1.45"),
  )
  assert_eq(@docker_cli.HttpResponse::header(response, "missing"), None)
}

///|
/// URI 解析：只要 `unix://`，其余协议明确返回 None。
async test "unix uri parsing accepts only unix scheme" {
  let uri = @docker_cli.parse_unix_uri("unix:///var/run/docker.sock").unwrap()
  assert_eq(uri.path, "/var/run/docker.sock")
  assert_eq(uri.host, "localhost")
  assert_true(@docker_cli.parse_unix_uri("tcp://1.2.3.4:2375") is None)
  assert_true(@docker_cli.parse_unix_uri("unix://") is None)
}

///|
/// Engine 后端的路径要按协商到的版本拼前缀。
async test "engine paths carry the negotiated api prefix" {
  let uri = @docker_cli.parse_unix_uri("unix:///var/run/docker.sock").unwrap()
  let source = @docker_cli.EngineSource::new(uri)
  assert_eq(
    @docker_cli.EngineSource::api_path(source, "/images/x/json"),
    "/images/x/json",
  )
  @docker_cli.EngineSource::set_api_version(source, "1.45")
  assert_eq(
    @docker_cli.EngineSource::api_path(source, "/images/x/json"),
    "/v1.45/images/x/json",
  )
}

///|
/// 镜像名里的特殊字符要编码，但 `/` 与 `:` 要保留，否则 daemon 认不出引用。
async test "engine encodes image references" {
  assert_eq(@docker_cli.encode_ref_for_test("nginx:latest"), "nginx:latest")
  assert_eq(
    @docker_cli.encode_ref_for_test("myorg/myapp:1.0"),
    "myorg/myapp:1.0",
  )
  assert_eq(@docker_cli.encode_ref_for_test("a b"), "a%20b")
  assert_eq(@docker_cli.encode_ref_for_test("a?b"), "a%3fb")
}

///|
/// `name:tag` 拆分，注意 registry 带端口的情况。
async test "engine splits image references into name and tag" {
  assert_eq(@docker_cli.split_reference_for_test("nginx"), ("nginx", "latest"))
  assert_eq(
    @docker_cli.split_reference_for_test("nginx:1.25"),
    ("nginx", "1.25"),
  )
  // registry 端口不是 tag 分隔符
  assert_eq(
    @docker_cli.split_reference_for_test("localhost:5000/img"),
    ("localhost:5000/img", "latest"),
  )
  assert_eq(
    @docker_cli.split_reference_for_test("localhost:5000/img:2"),
    ("localhost:5000/img", "2"),
  )
  // digest 引用整体当 name
  assert_eq(
    @docker_cli.split_reference_for_test("nginx@sha256:abc"),
    ("nginx@sha256:abc", "latest"),
  )
}

///|
/// Engine 的错误响应体是 `{"message": "..."}`，要把它提出来当错误详情。
async test "engine extracts daemon error messages" {
  let response : @docker_cli.HttpResponse = {
    status: 404,
    headers: [],
    body: @utf8.encode("{\"message\":\"No such image: nope\"}"),
  }
  assert_eq(@docker_cli.error_body_for_test(response), "No such image: nope")
  let plain : @docker_cli.HttpResponse = {
    status: 500,
    headers: [],
    body: @utf8.encode("internal server error"),
  }
  assert_eq(@docker_cli.error_body_for_test(plain), "internal server error")
}

///|
/// pull 的 raw-stream 里没有 error 字段时算成功：进度行、`status`、`id` 都要能跳过。
async test "pull stream without errors is a success" {
  let stream =
    #|{"status":"Pulling from library/nginx","id":"latest"}
    #|{"status":"Pulling fs layer","id":"0a3621ec1dd4"}
    #|{"status":"Download complete","id":"f55e02ea8cde"}
    #|
  assert_true(@docker_cli.pull_error_of_stream(stream) is None)
}

///|
/// HTTP 200 之后 daemon 仍会在流里吐 `errorDetail`：
/// 镜像不存在、认证失败、registry 连不上都走这条路，只看状态码会把失败当成功。
async test "pull stream error detail is surfaced" {
  let stream =
    #|{"status":"Pulling from library/nope","id":"latest"}
    #|{"errorDetail":{"message":"manifest for nope:latest not found"},"error":"manifest for nope:latest not found"}
    #|
  assert_eq(
    @docker_cli.pull_error_of_stream(stream),
    Some("manifest for nope:latest not found"),
  )
}

///|
/// 老 daemon / 中间代理只回 `error`，没有 `errorDetail`，同样要抓住。
async test "pull stream falls back to the plain error field" {
  let line =
    #|{"error":"Get https://registry-1.docker.io/: dial tcp: i/o timeout"}
  assert_eq(
    @docker_cli.pull_error_of_stream(line),
    Some("Get https://registry-1.docker.io/: dial tcp: i/o timeout"),
  )
}

///|
/// 进度流里混着非 JSON 噪声（代理插的日志行、被截断的半行）不该让判定失败，
/// 但噪声**之后**的真错误仍要被抓到。
async test "pull stream skips noise but keeps looking for errors" {
  let stream =
    #|Connecting to registry...
    #|{"status":"Pulling fs layer"
    #|
    #|{"errorDetail":{"message":"unauthorized: authentication required"}}
    #|
  assert_eq(
    @docker_cli.pull_error_of_stream(stream),
    Some("unauthorized: authentication required"),
  )
}

///|
/// 空流（daemon 直接关连接）当作成功：后面 `save` 会因为「本地没有」失败，
/// 错误信息比这里凭空造一个更准。
async test "an empty pull stream is not an error" {
  assert_true(@docker_cli.pull_error_of_stream("") is None)
  assert_true(@docker_cli.pull_error_of_stream("\n\n") is None)
}
