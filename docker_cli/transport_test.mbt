///|
/// Engine 后端的**传输层**端到端测试。
///
/// `engine_test.mbt` 覆盖了请求组装、响应解析、版本前缀、引用编码、
/// 错误体提取——传输层之下和之上的每一层都测了，唯独「真有一条 unix socket、
/// 真发一次 HTTP、真读到 chunked 响应」没有。
///
/// 这里用一个测试专用的 unix socket 服务端（`unix_test_support.mbt` +
/// `unix_socket_stub.c`）补上：fake daemon 起在临时目录里，
/// `EngineSource` 通过 `http_over_unix` 真发请求、真读响应。
///
/// 只面向 POSIX；Windows 上没有 `AF_UNIX` 的稳定绑定，用例跳过。
#cfg(not(platform="windows"))
const CRLFCRLF : Bytes = b"\r\n\r\n"

///|
/// `_ping` 的响应，带 `Api-Version`。
#cfg(not(platform="windows"))
fn ping_response(api_version : String) -> Bytes {
  @utf8.encode(
    "HTTP/1.1 200 OK\r\n" +
    "Api-Version: \{api_version}\r\n" +
    "Content-Length: 2\r\n" +
    "\r\n" +
    "OK",
  )
}

///|
/// 按 `Content-Length` 回一个 JSON 体。
#cfg(not(platform="windows"))
fn length_response(status : Int32, body : Bytes) -> Bytes {
  let head = @utf8.encode(
    "HTTP/1.1 \{status} OK\r\n" +
    "Content-Type: application/json\r\n" +
    "Content-Length: \{body.length()}\r\n" +
    "\r\n",
  )
  head + body
}

///|
/// 按 `Transfer-Encoding: chunked` 分块回一个流。
/// `chunk_size` 控制每块多大，用来验证多块拼接与 0 块收尾。
#cfg(not(platform="windows"))
fn chunked_response(chunk_size : Int32, body : Bytes) -> Bytes {
  let parts = [
    @utf8.encode(
      "HTTP/1.1 200 OK\r\n" +
      "Content-Type: application/vnd.docker.raw-stream\r\n" +
      "Transfer-Encoding: chunked\r\n" +
      "\r\n",
    ),
  ]
  let mut offset = 0
  while offset < body.length() {
    let take = @cmp.minimum(chunk_size, body.length() - offset)
    parts.push(@utf8.encode("\{hex(take)}\r\n"))
    parts.push(body[offset:offset + take].to_owned())
    parts.push(b"\r\n")
    offset = offset + take
  }
  parts.push(b"0\r\n\r\n")
  let buffer = @buffer.Buffer()
  for part in parts {
    buffer.write_bytes(part)
  }
  buffer.to_bytes()
}

///|
/// 小写十六进制，`chunked_response` 拼块头用。
#cfg(not(platform="windows"))
fn hex(value : Int32) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let out = StringBuilder()
  let mut remaining = value
  let stack = []
  while remaining > 0 {
    stack.push(remaining % 16)
    remaining = remaining / 16
  }
  for index = stack.length() - 1; index >= 0; index = index - 1 {
    out.write_char(digits[stack[index]])
  }
  out.to_string()
}

///|
/// 起一个 fake daemon：读掉一个请求，按 `responder` 给出响应，再关连接。
#cfg(not(platform="windows"))
async fn serve_one(
  server : @docker_cli.UnixSocketServer,
  responder : async (Bytes) -> Bytes,
) -> Unit {
  let conn = server.accept() catch { err => fail("accept failed: \{err}") }
  let request = @docker_cli.read_until(conn, CRLFCRLF) catch {
    err => fail("reading request failed: \{err}")
  }
  let response = responder(request) catch {
    err => fail("responder failed: \{err}")
  }
  conn.write(response) catch {
    err => fail("writing response failed: \{err}")
  }
  conn.close()
}

///|
/// `http_over_unix` 真发出去一行 HTTP/1.1：服务端看到的就是它。
/// 这是「真有一根 socket、真发一次请求」的最小证明。
#cfg(not(platform="windows"))
async test "engine sends a real request over a unix socket" {
  let server = @docker_cli.UnixSocketServer::start()
  let seen = []
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, request => {
        seen.push(request)
        @utf8.encode("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
      })
    })
    let response = @docker_cli.http_over_unix(
      server.path,
      {
        http_method: "GET",
        path: "/_ping",
        host: "localhost",
        headers: [],
        body: b"",
      },
      5000,
    ) catch {
      err => fail("http_over_unix failed: \{err}")
    }
    assert_eq(response.status, 200)
    assert_eq(@utf8.decode(response.body), "OK")
  })
  assert_eq(seen.length(), 1)
  let request = @utf8.decode(seen[0])
  assert_true(request.has_prefix("GET /_ping HTTP/1.1\r\n"))
  assert_true(request.contains("Host: localhost\r\n"))
  assert_true(request.has_suffix("\r\n\r\n"))
  server.close()
}

///|
/// `GET /images/{name}/json`：inspect 的响应走 `Content-Length` 读回来，
/// 再交给 `parse_inspect`。同时钉住版本前缀与引用编码真的落到请求行上。
#cfg(not(platform="windows"))
async test "engine inspects over the socket" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, request => {
        let text = @utf8.decode(request)
        assert_true(text.contains("GET /v1.45/images/nginx:latest/json"))
        length_response(
          200,
          @utf8.encode(
            "[{\"Id\":\"sha256:transport\",\"Architecture\":\"amd64\",\"Os\":\"linux\",\"Size\":2048}]",
          ),
        )
      })
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    @docker_cli.EngineSource::set_api_version(source, "1.45")
    let info = source.inspect("nginx:latest") catch {
      err => fail("inspect over socket failed: \{err}")
    }
    assert_eq(info.id, "sha256:transport")
    assert_eq(info.architecture, "amd64")
    assert_eq(info.size, 2048)
  })
  server.close()
}

///|
/// `_ping` 版本协商：daemon 回多少 `Api-Version`，后续路径就用哪个前缀。
#cfg(not(platform="windows"))
async test "engine negotiates the api version over the socket" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, _ => ping_response("1.41"))
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    let version = source.negotiate() catch {
      err => fail("negotiate failed: \{err}")
    }
    assert_eq(version, "/v1.41")
    assert_eq(
      @docker_cli.EngineSource::api_path(source, "/images/x/json"),
      "/v1.41/images/x/json",
    )
  })
  server.close()
}

///|
/// 老 daemon 不回 `Api-Version` 时退回 `1.24`：
/// 这是「路径还能拼出来」的兜底，不能断。
#cfg(not(platform="windows"))
async test "engine falls back to 1.24 without an api version header" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, _ => {
        @utf8.encode("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
      })
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    assert_eq(source.negotiate() catch { err => fail("\{err}") }, "/v1.24")
  })
  server.close()
}

///|
/// `GET /images/{name}/get` 的响应是 chunked 的 tar 流：
/// 分块要按序拼回原始归档，尾部 0 块要被正确收尾。
#cfg(not(platform="windows"))
async test "engine reads a chunked save stream over the socket" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=transport\n"),
  ])
  let archive = @docker_cli.build_docker_archive([("beef", layer)])
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      // 每块 7 字节：强制跨多块，验证拼接与 0 块收尾
      serve_one(server, _ => chunked_response(7, archive))
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    @docker_cli.EngineSource::set_api_version(source, "1.45")
    let saved = source.save("nginx:latest") catch {
      err => fail("save over socket failed: \{err}")
    }
    assert_eq(saved, archive)
    // 拿回来的归档要能被 P2 的既有解析吃掉
    let parsed = @docker_cli.parse_docker_archive(saved) catch {
      err => fail("saved archive should parse: \{err}")
    }
    assert_eq(@docker_cli.primary_entry(parsed).unwrap().layers.length(), 1)
  })
  server.close()
}

///|
/// 大 chunked 流：1MB、每块 8KB。这条盯传输正确性（不丢字节），
/// 与 `save_to_file` 的内存用例互补。
#cfg(not(platform="windows"))
async test "engine reads a large chunked stream intact" {
  let payload = FixedArray::make(1024 * 1024, b'\x5a').unsafe_reinterpret_as_bytes()
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, _ => chunked_response(8192, payload))
    })
    let response = @docker_cli.http_over_unix(
      server.path,
      {
        http_method: "GET",
        path: "/images/big/get",
        host: "localhost",
        headers: [],
        body: b"",
      },
      10000,
    ) catch {
      err => fail("http_over_unix failed: \{err}")
    }
    assert_eq(response.status, 200)
    assert_eq(response.body.length(), payload.length())
    assert_eq(response.body, payload)
  })
  server.close()
}

///|
/// 404 的错误体：daemon 的 `{"message": "..."}` 要被提出来当错误详情，
/// 而不是被吞成「退出码 404」。
#cfg(not(platform="windows"))
async test "engine surfaces the daemon error body over the socket" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, _ => {
        length_response(
          404,
          @utf8.encode("{\"message\":\"No such image: nope\"}"),
        )
      })
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    @docker_cli.EngineSource::set_api_version(source, "1.45")
    let error = try {
      source.inspect("nope") |> ignore
      fail("inspect should fail on 404")
    } catch {
      err => err
    }
    assert_true(error.to_string().contains("No such image: nope"))
  })
  server.close()
}

///|
/// 连接不上时给的是 `Backend` 而不是 panic：
/// socket 文件不存在 / daemon 没起，是运行时最常见的失败。
#cfg(not(platform="windows"))
async test "engine reports a missing daemon instead of panicking" {
  let dir = @fs.tmpdir(prefix="dive-nodaemon-") catch {
    err => fail("tmpdir: \{err}")
  }
  let path = "\{dir}/absent.sock"
  let source = @docker_cli.EngineSource::new(
    @docker_cli.parse_unix_uri("unix://\{path}").unwrap(),
  )
  let error = try {
    source.negotiate() |> ignore
    fail("negotiate should fail without a daemon")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("connect failed"))
  @fs.rmdir(dir, recursive=true)
}
