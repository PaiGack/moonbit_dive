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
  // 客户端可能已经走了（比如它拿到 404 就换下一条后端）：
  // 这时写回去会撞上 broken pipe，对 fake daemon 来说不是错误
  conn.write(response) catch {
    _ => ()
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
/// 404 不是「后端坏了」，是「这只后端说本地没有这个镜像」。
///
/// 这两件事必须分开：前者要换一条后端，后者要走「缺了就拉」。
/// 混成一个错误就只能靠猜——猜错的代价是把一次注定失败的拉取
/// 当成「镜像不在」的证明。daemon 给的 `message` 仍要在文案里能看见。
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
    assert_true(error is @docker_cli.ImageNotFound(_))
    assert_true(error.to_string().contains("nope"))
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

///|
/// `POST /images/create` 的传输层：请求行要带上 `fromImage` / `tag`，
/// 响应体（raw-stream）要原样读回来交给错误判定。
#cfg(not(platform="windows"))
async test "engine pulls over the socket" {
  let server = @docker_cli.UnixSocketServer::start()
  let seen = []
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, request => {
        seen.push(request)
        chunked_response(
          9,
          @utf8.encode(
            "{\"status\":\"Pulling fs layer\",\"id\":\"0a3621ec1dd4\"}\n" +
            "{\"status\":\"Download complete\"}\n",
          ),
        )
      })
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    @docker_cli.EngineSource::set_api_version(source, "1.45")
    source.pull("nginx:latest") catch {
      err => fail("pull over socket failed: \{err}")
    }
  })
  assert_eq(seen.length(), 1)
  let request = @utf8.decode(seen[0])
  assert_true(
    request.has_prefix(
      "POST /v1.45/images/create?fromImage=nginx&tag=latest HTTP/1.1\r\n",
    ),
  )
  server.close()
}

///|
/// HTTP 200 但流里有 `errorDetail`：`pull` 必须报错。
/// 只看状态码的实现会在这里悄悄放行，然后 `save` 拿着「本地没有」去猜。
#cfg(not(platform="windows"))
async test "engine pull fails when the stream carries an error" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, _ => {
        length_response(
          200,
          @utf8.encode(
            "{\"status\":\"Pulling from library/nope\"}\n" +
            "{\"errorDetail\":{\"message\":\"manifest for nope:latest not found\"}}\n",
          ),
        )
      })
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    @docker_cli.EngineSource::set_api_version(source, "1.45")
    let error = try {
      source.pull("nope:latest") |> ignore
      fail("pull should fail on a stream error")
    } catch {
      err => err
    }
    assert_true(
      error.to_string().contains("manifest for nope:latest not found"),
    )
  })
  server.close()
}

///|
/// `POST /images/create` 直接回 404：错误体里的 `message` 要被提出来。
#cfg(not(platform="windows"))
async test "engine pull surfaces an http error body" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      serve_one(server, _ => {
        length_response(
          500,
          @utf8.encode("{\"message\":\"error pulling image configuration\"}"),
        )
      })
    })
    let source = @docker_cli.EngineSource::new(
      @docker_cli.parse_unix_uri("unix://\{server.path}").unwrap(),
    )
    @docker_cli.EngineSource::set_api_version(source, "1.45")
    let error = try {
      source.pull("nginx:latest") |> ignore
      fail("pull should fail on 500")
    } catch {
      err => err
    }
    assert_true(error.to_string().contains("error pulling image configuration"))
  })
  server.close()
}

///|
/// issue #42 的第二层：socket **看着通**，真去取归档才发现这条路推不动。
///
/// CNB 这类环境里 `/var/run/docker.sock` 是外层转发进来的：探测阶段的
/// `_ping` 会答（所以判它可用），可真去 `GET /images/{name}/get` 时
/// 转发对象上没有这个镜像——只有真走一趟才知道。这时候不能就此收场，
/// 得顺着候选列表换到 PATH 上的 docker 再试一次。
///
/// 这里用一个「_ping 答、inspect 404」的 fake daemon 当那条半通的路，
/// 后面接一个 fake docker CLI。结果是 CLI 那条路给的归档。
#cfg(not(platform="windows"))
async test "a socket that answers _ping but cannot serve the image falls back" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      // 第一趟：探测时的 _ping
      serve_one(server, _ => ping_response("1.45"))
      // 第二趟：`resolve_backend` 建出来的 EngineSource 还没协商版本，
      // `inspect` 会自己补一次 `_ping`
      serve_one(server, _ => ping_response("1.45"))
      // 第三趟：inspect 说没有这个镜像（转发对象没有）= ImageNotFound
      serve_one(server, _ => {
        length_response(
          404,
          @utf8.encode("{\"message\":\"No such image: nope\"}"),
        )
      })
    })
    let resolved = @docker_cli.resolve_backend(
      [
        @docker_cli.BackendCandidate::Socket(server.path),
        @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
      ],
      // PATH 钉在空目录：CLI 那条候选不该被系统 docker 捡走
      { "PATH": "/nonexistent" },
      timeout_ms=1000,
    ) catch {
      err => fail("socket answers _ping, probing should pick it: \{err}")
    }
    // 探测确实选了 socket 那条路
    assert_true(resolved.backend is @docker_cli.ImageBackend::Engine(_))
    // 真去取归档：socket 给 404，链路要判它是「本地没有」而不是「路不通」
    let error = try {
      @docker_cli.save_or_pull_across_backends(
        [resolved.backend],
        0,
        "nope:latest",
        pull_if_missing=false,
      )
      |> ignore
      fail("save should fail on the socket")
    } catch {
      err => err
    }
    // 报的必须是「没有这个镜像」，不是「socket 坏了」——
    // 前端据此才知道该换路 / 该拉，而不是把整条后端判死
    assert_true(error is @docker_cli.ImageNotFound(_))
  })
  server.close()
}

///|
/// 换路真的会发生：socket 说「没有」，序列后面还有一条能用的 CLI，
/// 归档就该从 CLI 出来，而不是以 404 收场。
#cfg(not(platform="windows"))
async test "a dead socket path hands the fetch to the next backend" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=fallback\n"),
  ])
  let archive = @docker_cli.build_docker_archive([("fallback", layer)])
  let archive_path = @docker_cli.write_temp_bytes("fallback.tar", archive)
  let (bin, _program) = @docker_cli.write_fake_cli_named(
    "docker",
    @docker_cli.fake_recording_cli(
      archive_path + ".calls",
      archive_path,
      "[{\"Id\":\"sha256:fallback\"}]",
    ),
  )
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      // 探测时的 _ping
      serve_one(server, _ => ping_response("1.45"))
      // EngineSource 建出来时还没协商版本，inspect 自己会补一次 _ping
      serve_one(server, _ => ping_response("1.45"))
      // socket 那条路：inspect 报「没有这个镜像」
      serve_one(server, _ => {
        length_response(
          404,
          @utf8.encode("{\"message\":\"No such image: fallback\"}"),
        )
      })
    })
    let resolved = @docker_cli.resolve_backend(
      [
        @docker_cli.BackendCandidate::Socket(server.path),
        @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
      ],
      { "PATH": bin },
      timeout_ms=1000,
    ) catch {
      err => fail("probing should pick the socket: \{err}")
    }
    let chain = @docker_cli.backend_chain(
      [
        @docker_cli.BackendCandidate::Socket(server.path),
        @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
      ],
      resolved,
      { "PATH": bin },
      timeout_ms=1000,
    )
    // 序列里应当有两条：先行者 socket + 退路 CLI
    assert_true(chain.length() >= 2)
    let saved = @docker_cli.save_or_pull_across_backends(
      chain,
      0,
      "fallback:latest",
      pull_if_missing=false,
    ) catch {
      err => fail("the CLI backend should have picked this up: \{err}")
    }
    assert_eq(saved, archive)
  })
  server.close()
  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_temp_bytes(archive_path)
}

///|
/// 响应头发出去之后就不动了——这正是 CNB 里转发进来的 socket 的形态：
/// 文件在、`connect` 成功、状态行和头都答得出来，真读 body 时对端却没影了。
///
/// 期望：请求在超时内返回 `Cancelled`（说的是「超时」，不是某个 errno），
/// 而且错误信息里路径**只出现一次**——不能是
/// 「<path> failed: <path> failed: connect failed: errno 2」。
#cfg(not(platform="windows"))
async test "a socket that stalls mid-body surfaces a timeout, not a mangled errno" {
  let server = @docker_cli.UnixSocketServer::start()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      let conn = server.accept() catch { err => fail("accept failed: \{err}") }
      ignore(@docker_cli.read_until(conn, CRLFCRLF) catch { _ => b"" })
      // 头说 chunked，body 一个字节都不给，然后一直挂着
      conn.write(
        @utf8.encode(
          "HTTP/1.1 200 OK\r\n" + "Transfer-Encoding: chunked\r\n" + "\r\n",
        ),
      ) catch {
        _ => ()
      }
      @async.sleep(5000)
      conn.close()
    })
    let error = try {
      @docker_cli.http_over_unix(
        server.path,
        {
          http_method: "GET",
          path: "/images/nope:latest/get",
          host: "localhost",
          headers: [],
          body: b"",
        },
        200,
      )
      |> ignore
      fail("a stalled body must not return a response")
    } catch {
      err => err
    }
    // 超时是 `Cancelled`：一句「超时」，不是「connect failed: errno 2」
    assert_true(error is @docker_cli.Cancelled(_))
    let text = Show::to_string(error)
    assert_true(text.contains("was cancelled"))
    // 路径只出现一次：不再是把渲染过的错误再包一层
    assert_eq(count_occurrences(text, server.path), 1)
  })
  server.close()
}

///|
/// 候选全失败时，报的必须是**第一条**（也就是被选中的那条后端）的原因。
///
/// 序列通常长这样：DOCKER_HOST 指的 socket → 不存在的 `/var/run/docker.sock`
/// → PATH 上的 CLI。真正在用的第一条超时之后，尾巴上那条够不着的兜底项
/// 会给出一个「connect failed: errno 2」，如果拿它当结果，用户看到的是
/// 「不是我用过的后端」「不像超时」的一句玄学——只能自己猜。
#cfg(not(platform="windows"))
async test "when every backend fails the first backend's reason is reported" {
  let first = @docker_cli.DockerCliSource::new(
    @docker_cli.fake_failing_cli("first backend is down", 1),
  )
  let second = @docker_cli.DockerCliSource::new(
    @docker_cli.fake_failing_cli("second backend is down", 1),
  )
  let error = try {
    @docker_cli.save_or_pull_across_backends(
      [
        @docker_cli.ImageBackend::Cli(first),
        @docker_cli.ImageBackend::Cli(second),
      ],
      0,
      "nope:latest",
      pull_if_missing=false,
    )
    |> ignore
    fail("both backends fail, this must not return")
  } catch {
    err => err
  }
  let text = Show::to_string(error)
  // 第一条的原因在，最后一条的原因不在主句里（只出现在逐条列表里）
  assert_true(text.contains("first backend is down"))
  assert_true(text.contains("backends tried"))
  assert_true(text.contains("second backend is down"))
}

///|
/// 一条 lane 的一轮：socket 后端说「没有这个镜像」，序列后面还有一条能用的
/// CLI，归档就该从 CLI 出来。返回 `""` 表示这一轮正常，否则是失败原因。
///
/// 返回字符串而不是直接 `fail()`，是为了让并发 lane 把各自的失败收集起来
/// 一次报出来——第一个失败就把整轮掐掉的话，看不到「失败了多少次」，
/// 也就分不清是环境噪声还是稳定复现。
#cfg(not(platform="windows"))
async fn eagain_round(round : Int32) -> String {
  // 归档每轮现造：与 `save` 出来的字节逐位比对，顺带把负载抬到真实水位
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=eagain-\{round}\n"),
  ])
  let archive = @docker_cli.build_docker_archive([("eagain", layer)])
  let archive_path = write_temp_bytes("eagain-\{round}.tar", archive)
  let (bin, _program) = @docker_cli.write_fake_cli_named(
    "docker",
    @docker_cli.fake_recording_cli(
      archive_path + ".calls",
      archive_path,
      "[{\"Id\":\"sha256:eagain\"}]",
    ),
  )
  let server = @docker_cli.UnixSocketServer::start() catch {
    err => return "server: \{err}"
  }
  let reason = try {
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        serve_one(server, _ => ping_response("1.45"))
        serve_one(server, _ => ping_response("1.45"))
        serve_one(server, _ => {
          length_response(
            404,
            @utf8.encode("{\"message\":\"No such image: eagain\"}"),
          )
        })
      })
      let resolved = @docker_cli.resolve_backend(
        [
          @docker_cli.BackendCandidate::Socket(server.path),
          @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
        ],
        { "PATH": bin },
        timeout_ms=1000,
      ) catch {
        err => fail("round \{round}: probe failed: \{err}")
      }
      let chain = @docker_cli.backend_chain(
        [
          @docker_cli.BackendCandidate::Socket(server.path),
          @docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker),
        ],
        resolved,
        { "PATH": bin },
        timeout_ms=1000,
      )
      let saved = @docker_cli.save_or_pull_across_backends(
        chain,
        0,
        "eagain:latest",
        pull_if_missing=false,
      ) catch {
        err => fail("round \{round}: \{err}")
      }
      if saved != archive {
        fail(
          "round \{round}: archive mismatch, \{saved.length()} vs \{archive.length()} bytes",
        )
      }
    })
    ""
  } catch {
    err => err.to_string()
  }
  server.close()
  @docker_cli.remove_fake_cli_dir(bin)
  remove_temp_bytes(archive_path)
  reason
}

///|
/// 并发的 CLI 读取不能把瞬时的 `EAGAIN` 当成后端故障，也不能丢字节。
///
/// 复现手法：多条 lane 同时跑「unix socket 后端说没有 + CLI 兜底」这条完整链路
/// （就是上面换路用例的形状），每条 lane 再循环多轮。同一事件循环上既有 socket
/// 收发、又有子进程 spawn / 读管道，与 `moon test` 默认 10 路并发跑测试的情形
/// 一致——单跑一个用例复现不了，必须凑齐并发度。
///
/// 触发的是 `moonbitlang/async` 用边沿触发（`EPOLLET`）注册管道 fd 的窗口：
/// `wait_read()` 刚返回、真正 `read(2)` 却拿到 `EAGAIN`（就绪边沿被别处消费掉了）。
/// 底层只重试一次，第二次仍 `EAGAIN` 就抛出来。修复前这会变成
/// `Backend("read", ...)`——报出来跟「docker 用不了」一模一样，而子进程
/// 其实好得很；若拿一次性的 `read_all()` 去重试，更会退化成「退出码 0、
/// 输出为空」的假成功，比报错更难查。
///
/// 所以这里不只断言「不报错」，还逐字节校验归档内容。
#cfg(not(platform="windows"))
async test "concurrent cli reads survive transient EAGAIN without losing bytes" {
  let failures = []
  @async.with_task_group(group => {
    for lane in 0..<10 {
      group.spawn_bg(no_wait=true, () => {
        for round in 0..<30 {
          let reason = eagain_round(lane * 100 + round)
          if reason != "" {
            failures.push(reason)
          }
        }
      })
    }
  })
  if failures.length() > 0 {
    fail("cli reads failed \{failures.length()} times: \{failures[0]}")
  }
}
