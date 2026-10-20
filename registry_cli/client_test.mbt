///|
fn reply_of(status : Int32, location : String?) -> @registry_cli.HttpReply {
  let headers : Map[String, String] = Map([])
  match location {
    Some(location) => headers.set("location", location)
    None => ()
  }
  { status, headers, body: b"", source: None, }
}

///|
test "3xx responses count as redirects" {
  for status in [301, 302, 303, 307, 308] {
    assert_true(reply_of(status, None).is_redirect())
  }
  // 304 不是重定向：它没有 Location，跟着走只会绕圈
  assert_false(reply_of(304, None).is_redirect())
  assert_false(reply_of(200, None).is_redirect())
  assert_false(reply_of(401, None).is_redirect())
}

///|
test "absolute location keeps its own origin" {
  // blob 常被 307 到 CDN：目标 host 与 registry 不同，必须按 Location 走
  let (origin, path) = @registry_cli.resolve_location(
    "https://registry-1.docker.io", "https://production.cloudflare.docker.com/v2/x/blobs/sha256:abc?verify=1",
  ) catch {
    _ => fail("absolute location should resolve")
  }
  // origin 是「协议 + host」：`connect` 靠它决定 http 还是 https
  assert_eq(origin, "https://production.cloudflare.docker.com")
  assert_eq(path, "/v2/x/blobs/sha256:abc?verify=1")
}

///|
test "host-relative location stays on the registry" {
  let (origin, path) = @registry_cli.resolve_location(
    "https://localhost:5000", "/v2/library/nginx/blobs/sha256:abc",
  ) catch {
    _ => fail("relative location should resolve")
  }
  assert_eq(path, "/v2/library/nginx/blobs/sha256:abc")
  // origin 是连接时的 base（含协议），不是裸 host
  assert_true(origin.has_prefix("https://localhost:5000"))
}

///|
test "path-relative location is rejected with a readable message" {
  let error = try
    @registry_cli.resolve_location("https://localhost:5000", "../other")
  catch {
    err => err
  } noraise {
    _ => fail("a path-relative location should be rejected")
  }
  match error {
    @registry_cli.Network(message) =>
      assert_true(message.contains("relative location"))
    _ => fail("expected Network")
  }
}

///|
test "show of a reply keeps header lookup case-insensitive" {
  let headers : Map[String, String] = Map([("content-type", "application/json")])
  let reply : @registry_cli.HttpReply = {
    status: 200,
    headers,
    body: b"",
    source: None,
  }
  assert_eq(reply.header("Content-Type"), Some("application/json"))
  assert_eq(reply.header("content-type"), Some("application/json"))
  assert_true(reply.header("etag") is None)
}
