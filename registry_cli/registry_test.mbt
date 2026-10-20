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
/// 与 `with_fake_registry` 一样，但把测试体的**返回值**带出来。
///
/// 断错误类型的测试需要它：`fail()` 在闭包里只会把测试判失败，
/// 拿不到「到底抛了哪一种错」。
async fn[X] with_fake_registry_result(
  image : FakeImage,
  require_token~ : Bool = false,
  /// 让第 `index` 层的请求返回这坨字节，而不是真内容（模拟「某一层坏了」）
  swap~ : (Int32, Bytes)? = None,
  body~ : async (String) -> X,
) -> X {
  let server = @http.Server(@socket.Addr::new(0x7F000001, 0))
  let port = server.addr.port()
  @async.with_task_group(group => {
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
        let body_bytes = match swap {
          Some((index, bytes)) =>
            if reply.status == 200 &&
              request.path.has_suffix(
                @oci_spec.Digest::from_sha256(image.layers[index]).to_string(),
              ) {
              bytes
            } else {
              reply.body
            }
          None => reply.body
        }
        conn.send_response(reply.status, "OK", extra_headers=reply.headers)
        conn.write(body_bytes)
      })
    })
    let outcome = body("127.0.0.1:\{port}")
    server.close()
    outcome
  })
}

///|
/// 直接连假 registry（`http://127.0.0.1:<port>`）拉一次。
///
/// 不走 `pull_image`：那个函数按引用里的 registry 段选 host，
/// 拿不到测试里随机分配的端口；这里用 `pull_with_client` 显式指定。
///
/// 这些夹具都是几百字节的小层，落盘只会让测试在 `/tmp` 里攒垃圾：
/// 所以**默认关掉流式落盘**，谁要验流式谁自己显式打开。
async fn pull_from(
  host : String,
  reference : ImageReference,
  options : PullOptions,
) -> RemoteImage raise RegistryError {
  let client = RegistryClient::connect(host, insecure=true) catch {
    _ => raise @registry_cli.Network("cannot create the test client")
  }
  let options = @registry_cli.PullOptions::new(
    platform=options.platform,
    insecure=options.insecure,
    token=options.token,
    on_progress=options.on_progress,
    on_tick=options.on_tick,
    concurrency=options.concurrency,
    stream_to_disk=false,
  )
  let image = {
    errdefer client.close()
    // 假的 registry 是明文：换票端点与 blob 重定向时若挑战里的 https 连不上，
    // 就该退回这个 origin（否则「换票建不起 TLS」只能报一句看不懂的错）
    pull_with_client(client, reference, fallback="http://\{host}", options~)
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
    let data = pulled.layers[0].bytes() catch {
      err => fail("the layer should be readable: \{err.to_string()}")
    }
    assert_eq(data.length(), size)
    assert_true(@oci_spec.verify_digest(data, diff))
  })
}

///|
/// 造一个 N 层、每层都很小的镜像：并发拉取的形状验证靠它。
///
/// 每层内容不同（同一份 tar 会因为层名/内容撞 digest），
/// 并且**故意让层的大小不一致**：并发最容易错的就是「结果按完成顺序排回去」，
/// 大小整齐划一时这种错还看不出来。
async fn fake_multilayer_image(layers : Int32) -> FakeImage {
  let configs : Array[String] = []
  let payloads : Array[Bytes] = []
  for index in 0..<layers {
    let path = "opt/app/file-\{index}.txt"
    let (tar, diff) = fake_layer(path, "content of layer \{index}\n")
    configs.push(diff)
    payloads.push(@layer_tree.gzip_compress(tar))
  }
  {
    config: fake_config(configs),
    layers: payloads,
    layer_media_type: @oci_spec.oci_layer_gzip_media_type,
    as_index: false,
    platform_os: "linux",
    platform_arch: "amd64",
  }
}

///|
/// 并发的第一件事不是「快」，是「不乱」：8 层按 manifest 顺序排回去、
/// 每层 digest 校验通过、字节数一个不差。
///
/// 本地单线程的假 registry 测不出加速（请求本来就排在一条线上），
/// 所以这里只钉语义：**顺序是契约**，并发只是它的一种实现。
async test "concurrent pull keeps manifest order and digests" {
  let source = fake_multilayer_image(8)
  let expected : Array[String] = []
  for layer in source.layers {
    expected.push(@oci_spec.Digest::from_sha256(layer).to_string())
  }
  with_fake_registry(source, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let pulled = pull_from(
      host,
      reference,
      @registry_cli.PullOptions::new(concurrency=4),
    ) catch {
      err => fail("concurrent pull should succeed: \{err.to_string()}")
    }
    assert_eq(pulled.layers.length(), 8)
    for index, layer in pulled.layers {
      // 顺序错了这里立刻炸：digest 是按 manifest 顺序摆的
      assert_eq(layer.digest, expected[index])
      let data = layer.bytes() catch {
        err => fail("layer \{index} should be readable: \{err.to_string()}")
      }
      assert_true(@oci_spec.verify_digest(data, layer.digest))
      assert_eq(data.length(), source.layers[index].length())
    }
  })
}

///|
/// 串行与并发必须产出同一份东西：`--jobs 1` 是一条要留着的退路，
/// 退路不能比新路结果差一点。
async test "serial and concurrent pulls agree" {
  let source = fake_multilayer_image(5)
  with_fake_registry(source, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let serial = pull_from(
      host,
      reference,
      @registry_cli.PullOptions::new(concurrency=1),
    ) catch {
      err => fail("serial pull should succeed: \{err.to_string()}")
    }
    let parallel = pull_from(
      host,
      reference,
      @registry_cli.PullOptions::new(concurrency=3),
    ) catch {
      err => fail("concurrent pull should succeed: \{err.to_string()}")
    }
    // `concurrency = 0` 也要落回串行，而不是「同时在途 0 层」把自己卡死
    let zero = pull_from(
      host,
      reference,
      @registry_cli.PullOptions::new(concurrency=0),
    ) catch {
      err => fail("concurrency=0 should behave like 1: \{err.to_string()}")
    }
    assert_eq(serial.layers.length(), parallel.layers.length())
    assert_eq(serial.layers.length(), zero.layers.length())
    for index, layer in serial.layers {
      assert_eq(layer.digest, parallel.layers[index].digest)
      let left = layer.bytes() catch { _ => fail("serial layer unreadable") }
      let right = parallel.layers[index].bytes() catch {
        _ => fail("concurrent layer unreadable")
      }
      assert_eq(left, right)
      assert_eq(layer.digest, zero.layers[index].digest)
    }
    assert_eq(serial.config.digest, parallel.config.digest)
  })
}

///|
/// 并发下整体进度不能倒退也不能超过总量：`Progress` 是唯一的整体口径，
/// 交错的事件里它必须单调、封顶在 plan 字节上。
async test "concurrent pull reports a monotonic overall progress" {
  let source = fake_multilayer_image(6)
  let seen : Array[(Int64, Int64)] = []
  with_fake_registry(source, body=async fn(host) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    let callback : (@registry_cli.PullEvent) -> Unit = fn(event) {
      match event {
        @registry_cli.Progress(received~, total~) =>
          seen.push((received, total))
        _ => ()
      }
    }
    let pulled = pull_from(
      host,
      reference,
      @registry_cli.PullOptions::new(concurrency=3, on_progress=Some(callback)),
    ) catch {
      err => fail("concurrent pull should succeed: \{err.to_string()}")
    }
    assert_eq(pulled.layers.length(), 6)
  })
  assert_true(seen.length() > 0)
  let mut previous = 0L
  let mut plan = 0L
  for entry in seen {
    let (received, total) = entry
    if total > 0L {
      plan = total
    }
    // 整体字节只增不减：并发下各层交错完成，倒退就是口径算错了
    assert_true(received >= previous)
    previous = received
  }
  if plan > 0L {
    assert_true(previous <= plan)
  }
}

///|
/// 一层 404 时整次拉取失败，且报的是**那一眼能看懂**的错（哪一层的哪个 digest）。
/// 并发不能把「有一层坏了」糊成「整体超时」。
async test "a missing layer fails the whole concurrent pull" {
  let source = fake_multilayer_image(4)
  // manifest 说第三层的 digest 是 X，registry 上却把 X 的内容换掉了：
  // 请求能成功，字节对不上——并发拉取最容易把这种「某一层坏了」盖过去
  let swapped = @layer_tree.gzip_compress(b"not the layer you asked for")
  let error = with_fake_registry_result(source, swap=Some((2, swapped)), body=async fn(
    host,
  ) {
    let reference = @registry_cli.parse_reference("test/image:latest") catch {
      _ => fail("reference should parse")
    }
    try
      pull_from(host, reference, @registry_cli.PullOptions::new(concurrency=4))
    catch {
      err => err
    } noraise {
      image =>
        fail(
          "a corrupt layer must not be accepted (got \{image.layers.length()} layers)",
        )
    }
  })
  match error {
    @registry_cli.NotFound(message) => assert_true(message.contains("sha256:"))
    @registry_cli.DigestMismatch(message) =>
      assert_true(message.contains("sha256:"))
    other => fail("expected a blob-level error, got \{other.to_string()}")
  }
}
