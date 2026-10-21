///|
/// 直接造一个「已经拉下来」的镜像，不走网络——打包逻辑与网络无关。
async fn sample_image(gzip~ : Bool = true) -> RemoteImage {
  let (first, first_diff) = fake_layer("etc/motd", "hello\n")
  let (second, second_diff) = fake_layer("opt/app/run.sh", "#!/bin/sh\n")
  let layer_payload : Array[(Bytes, String)] = if gzip {
    [
      (@layer_tree.gzip_compress(first), @oci_spec.oci_layer_gzip_media_type),
      (@layer_tree.gzip_compress(second), @oci_spec.oci_layer_gzip_media_type),
    ]
  } else {
    [
      (first, @oci_spec.oci_layer_media_type),
      (second, @oci_spec.oci_layer_media_type),
    ]
  }
  let layers : Array[PulledBlob] = []
  for entry in layer_payload {
    let (data, media_type) = entry
    layers.push(
      @registry_cli.PulledBlob::in_memory(
        media_type~,
        digest=@oci_spec.Digest::from_sha256(data).to_string(),
        data~,
      ),
    )
  }
  let config = fake_config([first_diff, second_diff])
  {
    reference: sample_reference(),
    media_type: @oci_spec.oci_manifest_media_type,
    manifest_digest: @oci_spec.Digest::from_sha256(b"manifest").to_string(),
    config: @registry_cli.PulledBlob::in_memory(
      media_type=@oci_spec.oci_config_media_type,
      digest=@oci_spec.Digest::from_sha256(config).to_string(),
      data=config,
    ),
    layers,
    platform: None,
    staging: None,
  }
}

///|
fn sample_reference() -> ImageReference raise {
  @registry_cli.parse_reference("test/image:latest")
}

///|
/// 打 docker-archive 并读回落盘的 tar 字节。
///
/// 打包这一步是「自己写盘」的（见 `write_image`），所以测试要先把产物读回来
/// 再断言——这也顺带钉住了「写出去的东西真的是一个能读的 tar」。
async fn pack_docker_archive(image : RemoteImage) -> Bytes {
  let path = temp_path("tar")
  let _ = @registry_cli.write_image(
    image,
    path,
    format=@registry_cli.DockerArchive,
  ) catch {
    err => fail("packing should succeed: \{err.to_string()}")
  }
  let bytes = @xfs.read_file_to_bytes(path) catch {
    _ => fail("cannot read the packed archive back")
  }
  ignore(@xfs.remove_file(path) catch { _ => () })
  bytes
}

///|
/// 打 OCI layout，返回「相对路径 -> 字节」。
async fn pack_oci_layout(image : RemoteImage) -> Map[String, Bytes] {
  let path = temp_path("dir")
  let _ = @registry_cli.write_image(image, path, format=@registry_cli.OciLayout) catch {
    err => fail("packing should succeed: \{err.to_string()}")
  }
  let files : Map[String, Bytes] = Map([])
  let top = @xfs.read_dir(path) catch { _ => fail("cannot list the layout") }
  for name in top {
    let full = "\{path}/\{name}"
    if name == "blobs" {
      let algorithms = @xfs.read_dir(full) catch { _ => [] }
      for algorithm in algorithms {
        let blobs = @xfs.read_dir("\{full}/\{algorithm}") catch { _ => [] }
        for blob in blobs {
          let blob_path = "\{full}/\{algorithm}/\{blob}"
          files.set(
            "blobs/\{algorithm}/\{blob}",
            @xfs.read_file_to_bytes(blob_path) catch {
              _ => fail("cannot read \{blob_path}")
            },
          )
        }
      }
    } else {
      files.set(
        name,
        @xfs.read_file_to_bytes(full) catch {
          _ => fail("cannot read \{name}")
        },
      )
    }
  }
  remove_tree(path)
  files
}

///|
/// 递归删目录：`x/fs` 只有删空目录，测试自己得从中往外清。
///
/// 清不干净不只是「留垃圾」——同一个用例下次跑会撞上
/// 「目录已存在且非空」，报一个与被测逻辑无关的错误。
fn remove_tree(path : String) -> Unit {
  let entries = @xfs.read_dir(path) catch { _ => [] }
  for name in entries {
    let full = "\{path}/\{name}"
    let is_dir = @xfs.is_dir(full) catch { _ => false }
    if is_dir {
      remove_tree(full)
    } else {
      ignore(@xfs.remove_file(full) catch { _ => () })
    }
  }
  ignore(@xfs.remove_dir(path) catch { _ => () })
}

///|
/// 本次运行内不重复的临时路径。
///
/// 测试是串行跑的，进程内计数器就够了；带上类型后缀是为了让
/// 「文件」与「目录」两种产物一眼能分开，也避免互相踩。
fn temp_path(kind : String) -> String {
  counter.val = counter.val + 1
  "/tmp/dive-package-test-\{kind}-\{counter.val}"
}

///|
let counter : Ref[Int32] = Ref(0)

///|
async test "docker-archive is readable by the existing image reader" {
  let image = sample_image()
  let tar = pack_docker_archive(image)
  // `manifest.json` 里该有三个字段：Config / RepoTags / Layers
  let manifest_text = @layer_tree.read_file_from_tar(tar, "manifest.json").unwrap()
  let text = @encoding.decoder(UTF8).decode(manifest_text)
  assert_true(text.contains("\"Config\""))
  assert_true(text.contains("\"RepoTags\""))
  assert_true(text.contains("test/image:latest"))
  assert_true(text.contains("layer.tar"))
}

///|
async test "docker-archive layer ids are the diff ids from the config" {
  let image = sample_image()
  let tar = pack_docker_archive(image)
  let config_text = @encoding.decoder(UTF8).decode(
    image.config.bytes() catch {
      err => fail("config should be readable: \{err.to_string()}")
    },
  )
  let config = @oci_spec.parse_image_config_lenient(config_text)
  for diff_id in config.rootfs.diff_ids {
    let hex = diff_id[7:].to_owned()
    // 目录名就是未压缩层的 sha256：`<hex>/layer.tar` 必须真的存在
    assert_true(
      @layer_tree.read_file_from_tar(tar, "\{hex}/layer.tar") is Some(_),
    )
  }
}

///|
async test "docker-archive layers decompress back to the original tar" {
  let image = sample_image()
  let tar = pack_docker_archive(image)
  // 目录名是**未压缩层**的 sha256（diff id），不是压缩 blob 的 digest
  let config_text = @encoding.decoder(UTF8).decode(
    image.config.bytes() catch {
      err => fail("config should be readable: \{err.to_string()}")
    },
  )
  let config = @oci_spec.parse_image_config_lenient(config_text)
  let first_path = "\{config.rootfs.diff_ids[0][7:]}/layer.tar"
  let first = match @layer_tree.read_file_from_tar(tar, first_path) {
    Some(first) => first
    None => fail("layer tar \{first_path} is missing")
  }
  let entries = @layer_tree.parse_tar_entries(first)
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "etc/motd")
}

///|
/// zstd 层打 docker-archive：目录名仍是**解压后** tar 的 sha256，
/// 所以压不压缩对产物没有影响（docker 只认未压缩的 `layer.tar`）。
///
/// 层用**真 `zstd -19` 压过**的那份夹具（与 `layer_tree` 同一个文件）：
/// `layer_tree.zstd_compress` 只到 255 字节，装不下一个 tar。
async test "docker-archive unpacks zstd layers like gzip ones" {
  let blob = zstd_layer_fixture()
  let raw_layer = @layer_tree.zstd_decompress(blob[:])
  let diff_id = @oci_spec.Digest::from_sha256(raw_layer).to_string()
  let config = fake_config([diff_id])
  let image : RemoteImage = {
    reference: sample_reference(),
    media_type: @oci_spec.oci_manifest_media_type,
    manifest_digest: @oci_spec.Digest::from_sha256(b"manifest").to_string(),
    config: @registry_cli.PulledBlob::in_memory(
      media_type=@oci_spec.oci_config_media_type,
      digest=@oci_spec.Digest::from_sha256(config).to_string(),
      data=config,
    ),
    layers: [
      @registry_cli.PulledBlob::in_memory(
        media_type=@oci_spec.oci_layer_zstd_media_type,
        digest=@oci_spec.Digest::from_sha256(blob).to_string(),
        data=blob,
      ),
    ],
    platform: None,
    staging: None,
  }
  let tar = pack_docker_archive(image)
  // 目录名必须是**解压后** tar 的 sha256，而不是压缩 blob 的 digest
  let first_path = "\{diff_id[7:]}/layer.tar"
  let first = match @layer_tree.read_file_from_tar(tar, first_path) {
    Some(first) => first
    None => fail("layer tar \{first_path} is missing")
  }
  assert_eq(first, raw_layer)
  let paths = @layer_tree.parse_tar_entries(first).map(entry => entry.path)
  assert_eq(paths, ["etc/motd", "etc/"])
}

///|
/// 解不开的层不该被静默塞进归档：报错里要带上层 digest 和原因。
async test "docker-archive reports broken zstd layers" {
  let source = sample_image(gzip=false)
  let layers : Array[PulledBlob] = []
  for layer in source.layers {
    layers.push(
      @registry_cli.PulledBlob::in_memory(
        media_type=@oci_spec.oci_layer_zstd_media_type,
        digest=layer.digest,
        data=b"\x28\xb5\x2f\xfd not really a zstd frame",
      ),
    )
  }
  let image : RemoteImage = { ..source, layers, }
  let error = try
    @registry_cli.write_image(
      image,
      temp_path("broken"),
      format=@registry_cli.DockerArchive,
    )
  catch {
    err => err
  } noraise {
    _ => fail("a broken zstd layer must not be packed silently")
  }
  match error {
    @registry_cli.Unsupported(message) => {
      assert_true(message.contains("sha256:"))
      assert_true(message.contains("zstd"))
    }
    _ => fail("expected Unsupported")
  }
}

///|
async test "oci layout keeps blobs verbatim" {
  let image = sample_image()
  let files = pack_oci_layout(image)
  let names = files.keys().collect()
  assert_true(names.contains("oci-layout"))
  assert_true(names.contains("index.json"))
  // 每个 blob 都按 digest 命名，config 与层一个不少
  for layer in image.layers {
    assert_true(names.contains("blobs/sha256/\{layer.digest[7:]}"))
  }
  assert_true(names.contains("blobs/sha256/\{image.config.digest[7:]}"))
  // blob 内容原样，不重算
  for name, data in files {
    if name.has_prefix("blobs/sha256/") {
      let hex = name[13:].to_owned()
      assert_eq(
        @oci_spec.Digest::from_sha256(data).to_string(),
        "sha256:\{hex}",
      )
    }
  }
}

///|
async test "oci layout index points at the manifest blob" {
  let image = sample_image()
  let files = pack_oci_layout(image)
  let index_bytes = match files.get("index.json") {
    Some(data) => data
    None => fail("index.json is missing")
  }
  let index_text = @encoding.decoder(UTF8).decode(index_bytes)
  let index = @oci_spec.parse_document(index_text)
  let descriptors = match index {
    @oci_spec.IndexDoc(index) => index.manifests
    _ => fail("index.json is not an index")
  }
  assert_eq(descriptors.length(), 1)
  let digest = descriptors[0].digest
  // index 指的 manifest 必须真的在包里，否则 layout 是坏的
  assert_true(files.contains("blobs/sha256/\{digest[7:]}"))
  // 有 ref.name 才让 docker load / ctr import 恢复出 tag
  assert_true(index_text.contains("org.opencontainers.image.ref.name"))
}

///|
async test "format names parse both ways" {
  assert_true(@registry_cli.parse_format("docker-archive") is Some(_))
  assert_true(@registry_cli.parse_format("OCI") is Some(_))
  assert_true(@registry_cli.parse_format("tar") is Some(_))
  assert_true(@registry_cli.parse_format("tgz") is None)
}

///|
/// 真 `zstd -19` 压过的一份单层（`etc/motd`）。与 `layer_tree` 用的是同一种
/// 夹具：要证明「zstd 层能进 docker-archive」，手写编码器造的小帧不够看。
fn zstd_layer_fixture() -> Bytes raise {
  @xfs.read_file_to_bytes("registry_cli/fixtures/etc-motd-layer.tar.zst")
}

///|
/// issue #97 的回归：**打包**这一步不能把整层搬进内存。
///
/// 现场是 `dive <ref> --save -o x.tar` 打一个 700MB 的镜像：解压出来的层
/// 先攒成一块、再整段塞进 `TarWriter` 的 Buffer，最后又拷一遍——
/// 三份 700MB 顶到 Int32 的缓冲边界，报 `Buffer capacity overflow`。
///
/// 这里用 24MB 的层把同一条路径跑一遍（真按 700MB 造，测试自己会先被机器
/// 拖垮，而代码路径是同一段）：解压 → 写 tar → 落盘 → 再用既有的
/// docker-archive 读回来，逐字节对得上才算过。
///
/// 24MB 不是为了「大」，是为了让 32KB 的攒批边界被反复跨过：
/// 分块写与回拷窗口的错位只在这个尺度上才露出来。
async fn big_layer_image(size : Int32) -> RemoteImage {
  // 内容要有熵：全填同一个字节压完只剩几百字节，解压路径几乎不会被走到
  let payload = Bytes::makei(size, index => (index % 251).to_byte())
  // 层必须是**未压缩的 tar**（`docker save` 的 `layer.tar` 就是这个形状），
  // 所以拿真正的 tar 当内容：最后一步读回来时 `parse_tar_entries` 要认得出它
  let tar = build_payload_tar(payload)
  let diff_id = @oci_spec.Digest::from_sha256(tar).to_string()
  let config = fake_config([diff_id])
  let blob = @layer_tree.gzip_compress(tar)
  {
    reference: sample_reference(),
    media_type: @oci_spec.oci_manifest_media_type,
    manifest_digest: @oci_spec.Digest::from_sha256(b"manifest").to_string(),
    config: @registry_cli.PulledBlob::in_memory(
      media_type=@oci_spec.oci_config_media_type,
      digest=@oci_spec.Digest::from_sha256(config).to_string(),
      data=config,
    ),
    layers: [
      @registry_cli.PulledBlob::in_memory(
        media_type=@oci_spec.oci_layer_gzip_media_type,
        digest=@oci_spec.Digest::from_sha256(blob).to_string(),
        data=blob,
      ),
    ],
    platform: None,
    staging: None,
  }
}

///|
/// 造一个只含 `payload.bin` 的 tar，内容就是 `payload` 本身。
///
/// 这条用例要看的是「路径」，不是 tar 编码器的性能，所以这里也用流式写入器
/// 拼——`FiniteWriter` 是为了让测试的峰值内存只有一份 payload。
async fn build_payload_tar(payload : Bytes) -> Bytes {
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
/// 24MB 的层：打完包的 tar 能读回、层内容逐字节与解压结果一致。
///
/// 老写法在这条用例上就已经很勉强（三份 24MB），换到 700MB 就是 issue #97。
async test "packing a big layer streams instead of buffering it" {
  let size = 24 * 1024 * 1024
  let image = big_layer_image(size) catch {
    err => fail("fixture should build: \{err.to_string()}")
  }
  let tar = pack_docker_archive(image)
  let config_text = @encoding.decoder(UTF8).decode(
    image.config.bytes() catch {
      err => fail("config should be readable: \{err.to_string()}")
    },
  )
  let config = @oci_spec.parse_image_config_lenient(config_text)
  let layer_path = "\{config.rootfs.diff_ids[0][7:]}/layer.tar"
  let layer = match @layer_tree.read_file_from_tar(tar, layer_path) {
    Some(layer) => layer
    None => fail("layer tar \{layer_path} is missing from the archive")
  }
  // 目录名是未压缩层的 sha256：读回来的字节必须真的算得出这个名字
  assert_eq(
    @oci_spec.Digest::from_sha256(layer).to_string(),
    config.rootfs.diff_ids[0],
  )
  let entries = @layer_tree.parse_tar_entries(layer)
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "payload.bin")
  assert_eq(entries[0].size, size)
}

///|
/// 单遍打包：层只解压一次，两边（目录名里的 sha256 与 tar 里的字节）必须自洽。
///
/// issue #113 前的写法先整层解压一遍只为拿 `diff id`，再解压一遍写 tar——
/// 大镜像上这一项就是双倍 CPU。这里钉住的是「一遍也对」：
/// 名字里的摘要与写进 tar 的字节算出来的是同一个值。
async test "docker-archive is packed in a single pass" {
  let image = sample_image()
  let tar = pack_docker_archive(image)
  let config_text = @encoding.decoder(UTF8).decode(
    image.config.bytes() catch {
      err => fail("config should be readable: \{err.to_string()}")
    },
  )
  let config = @oci_spec.parse_image_config_lenient(config_text)
  // 每层都按「tar 里的字节」重算一遍摘要，与目录名（也就是 diff id）对齐
  for diff_id in config.rootfs.diff_ids {
    let path = "\{diff_id[7:]}/layer.tar"
    let layer = match @layer_tree.read_file_from_tar(tar, path) {
      Some(layer) => layer
      None => fail("layer \{path} is missing from the archive")
    }
    // 名字与字节必须自洽：一笔写出来的摘要是同一个值
    assert_eq(@oci_spec.Digest::from_sha256(layer).to_string(), diff_id)
  }
}
