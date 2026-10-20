///|
/// 一个最小的假 registry：真起一个 HTTP 服务，按 OCI Distribution 的样子答
/// `/v2/<repo>/manifests/<ref>` 与 `/v2/<repo>/blobs/<digest>`。
///
/// 为什么不用「打桩 HTTP 客户端」：这里的价值恰恰是**真的走一遍网络栈**——
/// URL 拼错、header 大小写、401 → 换票 → 重放这条链路，打桩一个都验不到。

///|
/// 假 registry 里摆着的一份镜像。
priv struct FakeImage {
  config : Bytes
  layers : Array[Bytes]
  /// 层在 manifest 里报的 media type（决定打包时解压还是原样存）
  layer_media_type : String
  /// 返回 index（multi-arch）而不是直接的 manifest
  mut as_index : Bool
  /// index 里那一项的平台
  platform_os : String
  mut platform_arch : String
}

///|
/// 假 registry 的应答身：`(状态码, 头, 体)`。
priv struct FakeReply {
  status : Int32
  headers : Map[@http.CaseInsensitiveString, String]
  body : Bytes
}

///|
/// 按请求路径给出应答。纯函数，方便单测，也免得把服务回调整成一坨。
fn FakeImage::reply(
  self : FakeImage,
  path : String,
  port : Int32,
  require_token : Bool,
  authorized : Bool,
) -> FakeReply {
  let manifest = manifest_bytes(self)
  let manifest_digest = @oci_spec.Digest::from_sha256(manifest).to_string()
  let config_digest = @oci_spec.Digest::from_sha256(self.config).to_string()
  if path.has_prefix("/token") {
    let body = @encoding.encode(
      UTF8,
      Json::object(Map([("token", Json::string("fake-token"))])).stringify(),
    )
    return { status: 200, headers: json_headers(), body, }
  }
  if require_token && !authorized {
    return { status: 401, headers: challenge_headers(port), body: b"", }
  }
  if path.contains("/manifests/") {
    // index 展开后，客户端会按子 manifest 的 digest 再请求同一个端点
    let suffix = match path.rev_find("/") {
      Some(index) => path[index + 1:].to_owned()
      None => ""
    }
    if self.as_index && suffix == manifest_digest {
      return {
        status: 200,
        headers: manifest_headers(@oci_spec.oci_manifest_media_type, suffix),
        body: manifest,
      }
    }
    if self.as_index {
      let index = index_bytes(manifest_digest, manifest, self)
      return {
        status: 200,
        headers: manifest_headers(
          @oci_spec.oci_index_media_type,
          @oci_spec.Digest::from_sha256(index).to_string(),
        ),
        body: index,
      }
    }
    return {
      status: 200,
      headers: manifest_headers(
        @oci_spec.oci_manifest_media_type, manifest_digest,
      ),
      body: manifest,
    }
  }
  if path.contains("/blobs/") {
    let digest = match path.rev_find("/") {
      Some(index) => path[index + 1:].to_owned()
      None => ""
    }
    if digest == config_digest {
      return { status: 200, headers: Map([]), body: self.config, }
    }
    for layer in self.layers {
      if @oci_spec.Digest::from_sha256(layer).to_string() == digest {
        return { status: 200, headers: Map([]), body: layer, }
      }
    }
    return { status: 404, headers: Map([]), body: b"", }
  }
  { status: 404, headers: Map([]), body: b"", }
}

///|
fn json_headers() -> Map[@http.CaseInsensitiveString, String] {
  Map([(@http.CaseInsensitiveString("content-type"), "application/json")])
}

///|
fn manifest_headers(
  media_type : String,
  digest : String,
) -> Map[@http.CaseInsensitiveString, String] {
  Map([
    (@http.CaseInsensitiveString("content-type"), media_type),
    (@http.CaseInsensitiveString("docker-content-digest"), digest),
  ])
}

///|
/// 挑战里的 realm 指向本服务：registry 与 auth 服务在真实世界常常是两台机器，
/// 但**同一台也完全合法**，而测试用它才能让换票真的走一遍网络。
fn challenge_headers(port : Int32) -> Map[@http.CaseInsensitiveString, String] {
  Map([
    (
      @http.CaseInsensitiveString("www-authenticate"),
      "Bearer realm=\"http://127.0.0.1:\{port}/token\",service=\"fake\",scope=\"repository:test/image:pull\"",
    ),
  ])
}

///|
fn manifest_bytes(image : FakeImage) -> Bytes {
  let layers : Array[Json] = []
  for layer in image.layers {
    layers.push(
      descriptor_json(
        image.layer_media_type,
        @oci_spec.Digest::from_sha256(layer).to_string(),
        layer.length(),
      ),
    )
  }
  let fields : Map[String, Json] = Map([])
  fields.set("schemaVersion", Json::number(2))
  fields.set("mediaType", Json::string(@oci_spec.oci_manifest_media_type))
  fields.set(
    "config",
    descriptor_json(
      @oci_spec.oci_config_media_type,
      @oci_spec.Digest::from_sha256(image.config).to_string(),
      image.config.length(),
    ),
  )
  fields.set("layers", Json::array(layers))
  @encoding.encode(UTF8, Json::object(fields).stringify())
}

///|
fn index_bytes(
  manifest_digest : String,
  manifest : Bytes,
  image : FakeImage,
) -> Bytes {
  let descriptor : Map[String, Json] = Map([])
  descriptor.set("mediaType", Json::string(@oci_spec.oci_manifest_media_type))
  descriptor.set("digest", Json::string(manifest_digest))
  descriptor.set("size", Json::number(manifest.length().to_double()))
  let platform : Map[String, Json] = Map([])
  platform.set("os", Json::string(image.platform_os))
  platform.set("architecture", Json::string(image.platform_arch))
  descriptor.set("platform", Json::object(platform))
  let fields : Map[String, Json] = Map([])
  fields.set("schemaVersion", Json::number(2))
  fields.set("mediaType", Json::string(@oci_spec.oci_index_media_type))
  fields.set("manifests", Json::array([Json::object(descriptor)]))
  @encoding.encode(UTF8, Json::object(fields).stringify())
}

///|
fn descriptor_json(media_type : String, digest : String, size : Int32) -> Json {
  let fields : Map[String, Json] = Map([])
  fields.set("mediaType", Json::string(media_type))
  fields.set("digest", Json::string(digest))
  fields.set("size", Json::number(size.to_double()))
  Json::object(fields)
}

///|
/// 一份最小的镜像 config。
fn fake_config(diff_ids : Array[String]) -> Bytes {
  let rootfs : Map[String, Json] = Map([])
  rootfs.set("type", Json::string("layers"))
  let ids : Array[Json] = []
  for diff_id in diff_ids {
    ids.push(Json::string(diff_id))
  }
  rootfs.set("diff_ids", Json::array(ids))
  let fields : Map[String, Json] = Map([])
  fields.set("architecture", Json::string("amd64"))
  fields.set("os", Json::string("linux"))
  fields.set("rootfs", Json::object(rootfs))
  @encoding.encode(UTF8, Json::object(fields).stringify())
}

///|
/// 造一层只有单个文件的 tar，返回 `(tar 字节, diff_id)`。
async fn fake_layer(path : String, content : String) -> (Bytes, String) {
  // 只在测试夹具里用：写完的 tar 本来就要整段留在内存里当假 registry 的 body
  let data = @encoding.encode(UTF8, content)
  let writer = @layer_tree.TarWriter::new()
  let sink = @registry_cli.BytesBuffer::new()
  let out : &@io.Writer = sink
  writer.write_entry(out, @layer_tree.tar_file_entry(path, data.length()), data)
  writer.finish(out)
  let tar = sink.to_bytes()
  (tar, @oci_spec.Digest::from_sha256(tar).to_string())
}

///|
/// 一份两层的假镜像：层是 gzip 的，config 记着未压缩 tar 的 diff id。
async fn fake_image() -> FakeImage {
  let (first, first_diff) = fake_layer("etc/motd", "hello\n")
  let (second, second_diff) = fake_layer("opt/app/run.sh", "#!/bin/sh\n")
  {
    config: fake_config([first_diff, second_diff]),
    layers: [
      @layer_tree.gzip_compress(first),
      @layer_tree.gzip_compress(second),
    ],
    layer_media_type: @oci_spec.oci_layer_gzip_media_type,
    as_index: false,
    platform_os: "linux",
    platform_arch: "amd64",
  }
}

///|
/// 在假 registry 的地址上跑一段测试体，跑完把服务关掉。
///
/// 用 `with_task_group` 而不是「后台线程」：async 库的结构化并发要求子任务
/// 有归属，任务组返回时保证全部收尾，测试不会漏掉一个还在监听的服务。
async fn with_fake_registry(
  image : FakeImage,
  require_token~ : Bool = false,
  body~ : async (String) -> Unit,
) -> Unit {
  let server = @http.Server(@socket.Addr::new(0x7F000001, 0))
  let port = server.addr.port()
  let result = @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      server.run_forever((request, _body, conn) => {
        let header = request.headers.get(
          @http.CaseInsensitiveString("authorization"),
        )
        let authorized = match header {
          Some(value) => value == "Bearer fake-token"
          None => false
        }
        let reply = image.reply(request.path, port, require_token, authorized)
        conn.send_response(reply.status, "OK", extra_headers=reply.headers)
        conn.write(reply.body)
      })
    })
    let outcome = body("127.0.0.1:\{port}")
    server.close()
    outcome
  })
  result
}

///|
/// 直接连假 registry（`http://127.0.0.1:<port>`）拉一次。
///
/// 不走 `pull_image`：那个函数按引用里的 registry 段选 host，
/// 拿不到测试里随机分配的端口；这里用 `pull_with_client` 显式指定。
async fn pull_from(
  host : String,
  reference : ImageReference,
  options : PullOptions,
) -> RemoteImage raise RegistryError {
  let client = RegistryClient::connect(host, insecure=true) catch {
    _ => raise @registry_cli.Network("cannot create the test client")
  }
  let image = {
    errdefer client.close()
    pull_with_client(client, reference, options~)
  }
  client.close()
  image
}

///|
/// 拉一份直接给 manifest 的镜像（最常见的情况）。
async test "pull a plain manifest image" {
  let image = fake_image()
  with_fake_registry(image, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let image = pull_from(host, reference, @registry_cli.PullOptions::new()) catch {
      err => fail("pull should succeed: \{err.to_string()}")
    }
    assert_eq(image.layers.length(), 2)
    assert_eq(image.config.media_type, @oci_spec.oci_config_media_type)
    // 平台是请求时给的那一个，不是 index 里挑出来的
    assert_true(image.platform is None)
    ignore(reference)
    ignore(host)
  })
}

///|
/// index → 按平台选子 manifest。
async test "pull selects a platform from an index" {
  let source = fake_image()
  source.as_index = true
  with_fake_registry(source, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let image = pull_from(
      host,
      reference,
      @registry_cli.PullOptions::new(
        platform=Some({
          architecture: "amd64",
          os: "linux",
          os_version: None,
          os_features: None,
          variant: None,
        }),
      ),
    ) catch {
      err => fail("pull should succeed: \{err.to_string()}")
    }
    assert_eq(image.layers.length(), 2)
    assert_true(image.platform is Some(_))
  })
}

///|
/// index 里没有目标平台时必须报「有哪些可选」，而不是一句 manifest unknown。
async test "pull reports the platforms when none match" {
  let source = fake_image()
  source.as_index = true
  source.platform_arch = "arm64"
  with_fake_registry(source, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let error = try
      pull_from(
        host,
        reference,
        @registry_cli.PullOptions::new(
          platform=Some({
            architecture: "s390x",
            os: "linux",
            os_version: None,
            os_features: None,
            variant: None,
          }),
        ),
      )
    catch {
      err => err
    } noraise {
      _ => fail("pull should fail on a missing platform")
    }
    match error {
      @registry_cli.NotFound(message) =>
        // 报错要列出真实存在的平台，否则等于没说
        assert_true(message.contains("linux/arm64"))
      _ => fail("expected NotFound")
    }
  })
}

///|
/// 401 → 换票 → 重放这条链路。
async test "pull survives a Bearer challenge" {
  let image = fake_image()
  with_fake_registry(image, require_token=true, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let image = pull_from(host, reference, @registry_cli.PullOptions::new()) catch {
      err =>
        fail("pull should succeed after the token exchange: \{err.to_string()}")
    }
    assert_eq(image.layers.length(), 2)
  })
}

///|
/// 大层不能再走「整段读到内存」的老路：700MB 的层在 `read_all` 里
/// 会先撞上 Int32 累加溢出（issue #97 的 `Buffer capacity overflow`）。
///
/// 这里用 24MB 的层把同一条代码路径跑一遍：分块读 + 边读边报进度。
/// 真按 700MB 造，测试自己会先被机器内存拖垮，而路径是同一段。
async fn pull_large_layer(
  host : String,
  reference : ImageReference,
) -> RemoteImage raise RegistryError {
  let client = RegistryClient::connect(host, insecure=true) catch {
    _ => raise @registry_cli.Network("cannot create the test client")
  }
  let image = {
    errdefer client.close()
    pull_with_client(client, reference, options=PullOptions::new())
  }
  client.close()
  image
}

///|
/// 一层 24MB 的镜像：每 1MB 报一次进度，最后收到的字节必须与 descriptor 一致。
async test "a big layer is read in chunks, not in one go" {
  let size = 24 * 1024 * 1024
  let layer = FixedArray::make(size, b'x')
  let bytes = layer.unsafe_reinterpret_as_bytes()
  let diff = @oci_spec.Digest::from_sha256(bytes).to_string()
  let image : FakeImage = {
    config: fake_config([diff]),
    layers: [bytes],
    layer_media_type: @oci_spec.oci_layer_gzip_media_type,
    as_index: false,
    platform_os: "linux",
    platform_arch: "amd64",
  }
  with_fake_registry(image, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let pulled = pull_large_layer(host, reference) catch {
      err => fail("pull should succeed: \{err.to_string()}")
    }
    assert_eq(pulled.layers.length(), 1)
    // 字节一个不差：分块拼接没算错长度也没漏掉尾巴
    assert_eq(pulled.layers[0].data.length(), size)
    assert_true(@oci_spec.verify_digest(pulled.layers[0].data, diff))
  })
}
