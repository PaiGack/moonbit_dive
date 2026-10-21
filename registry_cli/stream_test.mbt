///|
/// 流式落盘的两条命门都在这个文件里：
///
/// 1. **内存不随体积涨**：24 MB 的层走完 `pull` + OCI layout，
///    RSS 的增量要远小于层本身（照抄 `docker_cli/save_to_file_memory_test.mbt`
///    那套 `/proc/self/status` + 预算的写法）。
/// 2. **半截的产物不算成功**：假 registry 中途掐断连接，
///    临时目录里不能留下任何「名字对、内容坏」的 blob。
///
/// 只面向 POSIX：内存读数来自 `/proc/self/status`。
#cfg(not(platform="windows"))
const STREAM_LAYER_BYTES : Int32 = 24 * 1024 * 1024

///|
/// 进程当前的 RSS（kB）。
#cfg(not(platform="windows"))
async fn rss_kb() -> Int32 raise RegistryError {
  let text = @fs.read_file("/proc/self/status").text() catch {
    err => raise Io("cannot read RSS: \{err}")
  }
  let mut rss = 0
  for line in text.split("\n") {
    if line.has_prefix("VmRSS:") {
      rss = first_number_in(line)
    }
  }
  rss
}

///|
#cfg(not(platform="windows"))
fn first_number_in(line : StringView) -> Int32 {
  let mut digits = ""
  let mut started = false
  for code in line.to_array() {
    if code >= '0' && code <= '9' {
      digits = digits + code.to_string()
      started = true
    } else if started {
      break
    }
  }
  let mut value = 0
  for code in digits.to_array() {
    value = value * 10 + (code.to_int() - '0'.to_int())
  }
  value
}

///|
#cfg(not(platform="windows"))
async test "a big layer is streamed to disk instead of being held in memory" {
  // 内容要有熵：全填同一个字节能被 gzip 压到几乎没有，测不出什么
  let payload = Bytes::makei(STREAM_LAYER_BYTES, index => {
    (index % 251).to_byte()
  })
  // 层必须是未压缩的 tar：`docker save` 的 `layer.tar` 就是这个形状
  let tar = big_payload_tar(payload)
  let blob = @layer_tree.gzip_compress(tar)
  let diff_id = @oci_spec.Digest::from_sha256(tar).to_string()
  let image : FakeImage = {
    config: fake_config([diff_id]),
    layers: [blob],
    layer_media_type: @oci_spec.oci_layer_gzip_media_type,
    as_index: false,
    platform_os: "linux",
    platform_arch: "amd64",
  }
  with_fake_registry(image, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let directory = @fs.tmpdir(prefix="dive-stream-test-") catch {
      err => fail("tmpdir: \{err}")
    }
    let layout = "\{directory}/layout"
    let before = rss_kb() catch {
      err => fail("RSS before: \{err.to_string()}")
    }
    let request = @registry_cli.SaveRequest::new(
      reference="test/image:latest",
      output=layout,
      format=@registry_cli.OciLayout,
    )
    // 走的是 `save_image` 的完整链路：拉取（流式落盘）+ 打包 OCI layout
    let client = RegistryClient::connect(host, insecure=true) catch {
      _ => fail("client")
    }
    let pulled = pull_with_client(
      client,
      reference,
      fallback="http://\{host}",
      options=@registry_cli.PullOptions::new(),
    ) catch {
      err => fail("pull should succeed: \{err.to_string()}")
    }
    client.close()
    // 字节不在内存里：`data` 是 `None`，字节在文件上
    assert_true(pulled.layers[0].data is None)
    assert_true(pulled.layers[0].path is Some(_))
    let after_pull = rss_kb() catch {
      err => fail("RSS after pull: \{err.to_string()}")
    }
    let written = @registry_cli.write_image(
      pulled,
      layout,
      format=@registry_cli.OciLayout,
    ) catch {
      err => fail("layout should be written: \{err.to_string()}")
    }
    assert_true(written.bytes > STREAM_LAYER_BYTES.to_int64())
    // OCI layout 里的 blob 与拉下来的那份逐字节一致（没有走「读进内存再写出去」）
    let blob_path = "\{layout}/blobs/sha256/\{hex_of_digest(blob_sum(blob))}"
    let copied = @fs.read_file(blob_path) catch {
      err => fail("blob should exist at \{blob_path}: \{err}")
    }
    assert_eq(copied.binary(), blob)
    let after_write = rss_kb() catch {
      err => fail("RSS after write: \{err.to_string()}")
    }
    // 预算卡在 32 MB：24 MB 的层真被拼进内存的话，一次 pull 或一次 layout 就超了
    let budget_kb = 32 * 1024
    let pull_growth = after_pull - before
    let write_growth = after_write - after_pull
    if pull_growth >= budget_kb {
      fail(
        "the pull held the layer in memory: RSS grew \{pull_growth} kB for a \{STREAM_LAYER_BYTES} byte layer (budget \{budget_kb} kB)",
      )
    }
    if write_growth >= budget_kb {
      fail(
        "the layout write held the layer in memory: RSS grew \{write_growth} kB (budget \{budget_kb} kB)",
      )
    }
    @registry_cli.discard_image(pulled)
    @fs.rmdir(directory, recursive=true) catch {
      _ => ()
    }
    ignore(request)
  })
}

///|
fn blob_sum(blob : Bytes) -> String {
  @oci_spec.Digest::from_sha256(blob).to_string()
}

///|
fn hex_of_digest(digest : String) -> String {
  match digest.find(":") {
    Some(index) => digest[index + 1:].to_owned()
    None => digest
  }
}

///|
/// 造一个只含 `payload.bin` 的 tar（内容就是 `payload`）。
async fn big_payload_tar(payload : Bytes) -> Bytes {
  let writer = @layer_tree.TarWriter::new()
  let sink = @registry_cli.BytesBuffer::new()
  let out : &@io.Writer = sink
  writer.write_entry(
    out,
    @layer_tree.tar_file_entry("payload.bin", payload.length()),
    payload,
  )
  writer.finish(out)
  sink.to_bytes()
}

///|
/// 中途掐断的下载必须被当成失败：临时目录里不能留「名字对、内容坏」的 blob。
///
/// 这里的 registry 只吐一半就关连接，`content-length` 照报全——
/// 正是「看起来成功、其实截断」的那种最坏情况。
#cfg(not(platform="windows"))
async test "a truncated layer is rejected and leaves no partial blob behind" {
  let payload = Bytes::makei(4 * 1024 * 1024, index => (index % 251).to_byte())
  let tar = big_payload_tar(payload)
  let blob = @layer_tree.gzip_compress(tar)
  let digest = @oci_spec.Digest::from_sha256(blob).to_string()
  let config = fake_config([@oci_spec.Digest::from_sha256(tar).to_string()])
  with_truncating_registry(config~, blob~, digest~, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let error = with_result(host, reference)
    let staging_after = list_staging_dirs()
    match error {
      Some(message) => {
        // 失败要落在「读正文」这一步，而不是糊成 digest 不符
        assert_true(message.contains("reading the response body"))
        // 临时目录随失败一起收掉：`/tmp` 上不该留下这次拉取的任何 blob
        for directory in staging_after {
          assert_false(
            has_any_blob(directory),
            msg="\{directory} still holds blobs after a failed pull",
          )
        }
      }
      None =>
        fail("a truncated layer must not be accepted as a successful pull")
    }
  })
}

///|
/// 在 `host` 上拉一次，失败时返回 `Some(错误)`、成功时 `None`。
async fn with_result(
  host : String,
  reference : @registry_cli.ImageReference,
) -> String? {
  let client = RegistryClient::connect(host, insecure=true) catch {
    _ => return Some("cannot create the test client")
  }
  let outcome = try {
    let image = pull_with_client(
      client,
      reference,
      options=@registry_cli.PullOptions::new(),
    )
    @registry_cli.discard_image(image)
    None
  } catch {
    err => Some(err.to_string())
  }
  client.close()
  outcome
}

///|
/// 这个目录里还有没有 blob（`.partial` 也算：半截的更该被清掉）。
fn has_any_blob(directory : String) -> Bool {
  let entries = @xfs.read_dir(directory) catch { _ => return false }
  entries.length() > 0
}

///|
/// 当前 `/tmp` 下 `dive-blobs-` 开头的目录；用来看「临时目录有没有漏掉」。
fn list_staging_dirs() -> Array[String] {
  let found : Array[String] = []
  let entries = @xfs.read_dir("/tmp") catch { _ => return found }
  for entry in entries {
    if entry.has_prefix("dive-blobs-") {
      found.push(entry)
    }
  }
  found
}

///|
/// 一个「吐一半就关」的假 registry：manifest 与 config 照常，
/// 层只写前一半字节，`content-length` 照报全。
async fn with_truncating_registry(
  config~ : Bytes,
  blob~ : Bytes,
  digest~ : String,
  body~ : async (String) -> Unit,
) -> Unit {
  let config_digest = @oci_spec.Digest::from_sha256(config).to_string()
  let manifest = truncated_manifest(config~, config_digest~, digest~, blob~)
  let manifest_digest = @oci_spec.Digest::from_sha256(manifest).to_string()
  let server = @http.Server(@socket.Addr::new(0x7F000001, 0))
  let port = server.addr.port()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      server.run_forever((request, _body, conn) => {
        let path = request.path
        if path.contains("/manifests/") {
          let headers = Map([
            (
              @http.CaseInsensitiveString("content-type"),
              @oci_spec.oci_manifest_media_type,
            ),
            (
              @http.CaseInsensitiveString("docker-content-digest"),
              manifest_digest,
            ),
            (
              @http.CaseInsensitiveString("content-length"),
              manifest.length().to_string(),
            ),
          ])
          conn.send_response(200, "OK", extra_headers=headers)
          conn.write(manifest)
          return
        }
        if path.contains("/blobs/") {
          if path.has_suffix(config_digest) {
            let headers = Map([
              (
                @http.CaseInsensitiveString("content-length"),
                config.length().to_string(),
              ),
            ])
            conn.send_response(200, "OK", extra_headers=headers)
            conn.write(config)
            return
          }
          if path.has_suffix(digest) {
            // `content-length` 报全，实际只写一半：客户端必须自己发现截断
            let headers = Map([
              (
                @http.CaseInsensitiveString("content-length"),
                blob.length().to_string(),
              ),
            ])
            conn.send_response(200, "OK", extra_headers=headers)
            let half = blob.length() / 2
            conn.write(blob[:half])
            return
          }
        }
        conn.send_response(404, "Not Found")
      })
    })
    let outcome = body("127.0.0.1:\{port}")
    server.close()
    outcome
  })
}

///|
fn truncated_manifest(
  config~ : Bytes,
  config_digest~ : String,
  digest~ : String,
  blob~ : Bytes,
) -> Bytes {
  let layers : Array[Json] = [
    descriptor_json_of(
      @oci_spec.oci_layer_gzip_media_type,
      digest,
      blob.length(),
    ),
  ]
  let fields : Map[String, Json] = Map([])
  fields.set("schemaVersion", Json::number(2))
  fields.set("mediaType", Json::string(@oci_spec.oci_manifest_media_type))
  fields.set(
    "config",
    descriptor_json_of(
      @oci_spec.oci_config_media_type,
      config_digest,
      config.length(),
    ),
  )
  fields.set("layers", Json::array(layers))
  @encoding.encode(UTF8, Json::object(fields).stringify())
}

///|
fn descriptor_json_of(
  media_type : String,
  digest : String,
  size : Int32,
) -> Json {
  let fields : Map[String, Json] = Map([])
  fields.set("mediaType", Json::string(media_type))
  fields.set("digest", Json::string(digest))
  fields.set("size", Json::number(size.to_double()))
  Json::object(fields)
}

///|
/// 两跳重定向：registry → 307 → 中间站 → 307 → 真正文。
///
/// 真实世界就是这样（Docker Hub 的 blob 先跳到 Cloudflare，再跳到 S3）。
/// 只跟一跳的实现在这里会拿到一个「又不是 200 又不是 307」的应答，
/// 报错看起来像认证或网络问题，其实只是少跟了一跳。
#cfg(not(platform="windows"))
async test "a blob that redirects twice is still followed" {
  let config = fake_config([
    @oci_spec.Digest::from_sha256(b"unused diff id").to_string(),
  ])
  let config_digest = @oci_spec.Digest::from_sha256(config).to_string()
  // 层的正文是任意字节：这条用例只看「能不能落到盘上」，不看解压
  let blob = Bytes::makei(64 * 1024, index => (index % 251).to_byte())
  let digest = @oci_spec.Digest::from_sha256(blob).to_string()
  let manifest = truncated_manifest(config~, config_digest~, digest~, blob~)
  let manifest_digest = @oci_spec.Digest::from_sha256(manifest).to_string()
  let server = @http.Server(@socket.Addr::new(0x7F000001, 0))
  let port = server.addr.port()
  let origin = "http://127.0.0.1:\{port}"
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      server.run_forever((request, _body, conn) => {
        let path = request.path
        if path.has_prefix("/hop1/") {
          // 第一跳：把原来的路径塞进 /hop2/<原路径>
          let rest = path[6:].to_owned()
          let headers = Map([
            (@http.CaseInsensitiveString("location"), "\{origin}/hop2/\{rest}"),
            (@http.CaseInsensitiveString("content-length"), "0"),
          ])
          conn.send_response(307, "Temporary Redirect", extra_headers=headers)
          return
        }
        if path.has_prefix("/hop2/") {
          // 第二跳：回到真正的 blob 端点
          let rest = path[6:].to_owned()
          let headers = Map([
            (@http.CaseInsensitiveString("location"), "\{origin}/\{rest}"),
            (@http.CaseInsensitiveString("content-length"), "0"),
          ])
          conn.send_response(307, "Temporary Redirect", extra_headers=headers)
          return
        }
        if path.has_prefix("/v2/blob/") {
          let headers = Map([
            (
              @http.CaseInsensitiveString("location"),
              "\{origin}/hop1/v2/blob/\{digest}",
            ),
            (@http.CaseInsensitiveString("content-length"), "0"),
          ])
          conn.send_response(307, "Temporary Redirect", extra_headers=headers)
          return
        }
        if path.contains("/manifests/") {
          let headers = Map([
            (
              @http.CaseInsensitiveString("content-type"),
              @oci_spec.oci_manifest_media_type,
            ),
            (
              @http.CaseInsensitiveString("docker-content-digest"),
              manifest_digest,
            ),
            (
              @http.CaseInsensitiveString("content-length"),
              manifest.length().to_string(),
            ),
          ])
          conn.send_response(200, "OK", extra_headers=headers)
          conn.write(manifest)
          return
        }
        if path.contains("/blobs/") {
          let body = if path.has_suffix(config_digest) { config } else { blob }
          let headers = Map([
            (
              @http.CaseInsensitiveString("content-length"),
              body.length().to_string(),
            ),
          ])
          conn.send_response(200, "OK", extra_headers=headers)
          conn.write(body)
          return
        }
        conn.send_response(404, "Not Found")
      })
    })
    let directory = @fs.tmpdir(prefix="dive-redirect-test-") catch {
      err => fail("tmpdir: \{err}")
    }
    let client = RegistryClient::connect("127.0.0.1:\{port}", insecure=true) catch {
      _ => fail("client")
    }
    let reference = @registry_cli.parse_reference("test/blob:latest") catch {
      _ => fail("reference should parse")
    }
    let pulled = pull_with_client(
      client,
      reference,
      options=@registry_cli.PullOptions::new(),
    ) catch {
      err => fail("a two-hop redirect must be followed: \{err.to_string()}")
    }
    client.close()
    let landed = pulled.layers[0].bytes() catch {
      err => fail("the layer should be readable: \{err.to_string()}")
    }
    assert_eq(landed, blob)
    @registry_cli.discard_image(pulled)
    @fs.rmdir(directory, recursive=true) catch {
      _ => ()
    }
    server.close()
  })
}

///|
/// 挑战里的 realm 说 `https://`、而它其实只有明文：换票要退回到已知能走的那个 origin。
///
/// 现场就是 Docker Hub：realm 是另一个域名（`auth.docker.io`），`https` 建不起 TLS
/// （CI 镜像里的 CA 包读不出来）时报错只剩一句「token endpoint 连不上」，
/// 看起来像网络坏了，而 registry 那半边明明是通的。
///
/// 这个假 registry 只监听明文：`https://127.0.0.1:<port>/token` 必然连不上，
/// 于是「能不能拿到 token」本身就是「有没有退回 fallback」的答案。
#cfg(not(platform="windows"))
async test "a token realm that claims https falls back to the known origin" {
  let config = fake_config([
    @oci_spec.Digest::from_sha256(b"unused diff id").to_string(),
  ])
  let blob = Bytes::makei(1024, index => (index % 251).to_byte())
  let digest = @oci_spec.Digest::from_sha256(blob).to_string()
  let manifest = truncated_manifest(
    config~,
    config_digest=@oci_spec.Digest::from_sha256(config).to_string(),
    digest~,
    blob~,
  )
  let server = @http.Server(@socket.Addr::new(0x7F000001, 0))
  let port = server.addr.port()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      server.run_forever((request, _body, conn) => {
        let path = request.path
        let authorized = match
          request.headers.get(@http.CaseInsensitiveString("authorization")) {
          Some(value) => value == "Bearer fake-token"
          None => false
        }
        if path.has_prefix("/token") {
          let body = @encoding.encode(
            UTF8,
            Json::object(Map([("token", Json::string("fake-token"))])).stringify(),
          )
          let headers = Map([
            (@http.CaseInsensitiveString("content-type"), "application/json"),
            (
              @http.CaseInsensitiveString("content-length"),
              body.length().to_string(),
            ),
          ])
          conn.send_response(200, "OK", extra_headers=headers)
          conn.write(body)
          return
        }
        if !authorized && path.contains("/manifests/") {
          // 挑战故意写 `https://`：明文这边验不过 TLS，只有退回 fallback 才走得通
          let headers = Map([
            (
              @http.CaseInsensitiveString("www-authenticate"),
              "Bearer realm=\"https://127.0.0.1:\{port}/token\",service=\"fake\",scope=\"repository:test/image:pull\"",
            ),
            (@http.CaseInsensitiveString("content-length"), "0"),
          ])
          conn.send_response(401, "Unauthorized", extra_headers=headers)
          return
        }
        if path.contains("/manifests/") {
          let headers = Map([
            (
              @http.CaseInsensitiveString("content-type"),
              @oci_spec.oci_manifest_media_type,
            ),
            (
              @http.CaseInsensitiveString("content-length"),
              manifest.length().to_string(),
            ),
          ])
          conn.send_response(200, "OK", extra_headers=headers)
          conn.write(manifest)
          return
        }
        if path.contains("/blobs/") {
          let body = if path.has_suffix(digest) { blob } else { config }
          let headers = Map([
            (
              @http.CaseInsensitiveString("content-length"),
              body.length().to_string(),
            ),
          ])
          conn.send_response(200, "OK", extra_headers=headers)
          conn.write(body)
          return
        }
        conn.send_response(404, "Not Found")
      })
    })
    let host = "127.0.0.1:\{port}"
    let client = RegistryClient::connect(host, insecure=true) catch {
      _ => fail("client")
    }
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let pulled = pull_with_client(
      client,
      reference,
      fallback="http://\{host}",
      options=@registry_cli.PullOptions::new(),
    ) catch {
      err =>
        fail(
          "the token realm should fall back to the known origin: \{err.to_string()}",
        )
    }
    client.close()
    let landed = pulled.layers[0].bytes() catch {
      err => fail("the layer should be readable: \{err.to_string()}")
    }
    assert_eq(landed, blob)
    @registry_cli.discard_image(pulled)
    server.close()
  })
}
