///|
/// 直接造一个「已经拉下来」的镜像，不走网络——打包逻辑与网络无关。
fn sample_image(
  gzip~ : Bool = true,
) -> RemoteImage raise @registry_cli.RegistryError {
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
    layers.push({
      media_type,
      digest: @oci_spec.Digest::from_sha256(data).to_string(),
      data,
    })
  }
  let config = fake_config([first_diff, second_diff])
  {
    reference: sample_reference(),
    media_type: @oci_spec.oci_manifest_media_type,
    manifest_digest: @oci_spec.Digest::from_sha256(b"manifest").to_string(),
    config: {
      media_type: @oci_spec.oci_config_media_type,
      digest: @oci_spec.Digest::from_sha256(config).to_string(),
      data: config,
    },
    layers,
    platform: None,
  }
}

///|
fn sample_reference() -> ImageReference raise @registry_cli.RegistryError {
  @registry_cli.parse_reference("test/image:latest")
}

///|
/// 在 bundle 里按名字找一份字节。
fn bundle_file(bundle : ArchiveBundle, name : String) -> Bytes? {
  for entry in bundle.files {
    if entry.0 == name {
      return Some(entry.1)
    }
  }
  None
}

///|
test "docker-archive is readable by the existing image reader" {
  let image = sample_image()
  let bundle = @registry_cli.package_image(
    image,
    format=@registry_cli.DockerArchive,
  )
  assert_eq(bundle.files.length(), 1)
  let tar = bundle.files[0].1
  // `manifest.json` 里该有三个字段：Config / RepoTags / Layers
  let manifest_text = @layer_tree.read_file_from_tar(tar, "manifest.json").unwrap()
  let text = @encoding.decoder(UTF8).decode(manifest_text)
  assert_true(text.contains("\"Config\""))
  assert_true(text.contains("\"RepoTags\""))
  assert_true(text.contains("test/image:latest"))
  assert_true(text.contains("layer.tar"))
}

///|
test "docker-archive layer ids are the diff ids from the config" {
  let image = sample_image()
  let bundle = @registry_cli.package_image(
    image,
    format=@registry_cli.DockerArchive,
  )
  let tar = bundle.files[0].1
  let config_text = @encoding.decoder(UTF8).decode(image.config.data)
  let config = @oci_spec.parse_image_config_lenient(config_text).unwrap()
  for diff_id in config.rootfs.diff_ids {
    let hex = diff_id[7:].to_owned()
    // 目录名就是未压缩层的 sha256：`<hex>/layer.tar` 必须真的存在
    assert_true(
      @layer_tree.read_file_from_tar(tar, "\{hex}/layer.tar") is Some(_),
    )
  }
}

///|
test "docker-archive layers decompress back to the original tar" {
  let image = sample_image()
  let bundle = @registry_cli.package_image(
    image,
    format=@registry_cli.DockerArchive,
  )
  let tar = bundle.files[0].1
  // 目录名是**未压缩层**的 sha256（diff id），不是压缩 blob 的 digest
  let config_text = @encoding.decoder(UTF8).decode(image.config.data)
  let config = @oci_spec.parse_image_config_lenient(config_text).unwrap()
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
test "docker-archive unpacks zstd layers like gzip ones" {
  let blob = zstd_layer_fixture()
  let raw_layer = @layer_tree.zstd_decompress(blob[:])
  let diff_id = @oci_spec.Digest::from_sha256(raw_layer).to_string()
  let config = fake_config([diff_id])
  let image : RemoteImage = {
    reference: sample_reference(),
    media_type: @oci_spec.oci_manifest_media_type,
    manifest_digest: @oci_spec.Digest::from_sha256(b"manifest").to_string(),
    config: {
      media_type: @oci_spec.oci_config_media_type,
      digest: @oci_spec.Digest::from_sha256(config).to_string(),
      data: config,
    },
    layers: [
      {
        media_type: @oci_spec.oci_layer_zstd_media_type,
        digest: @oci_spec.Digest::from_sha256(blob).to_string(),
        data: blob,
      },
    ],
    platform: None,
  }
  let bundle = @registry_cli.package_image(
    image,
    format=@registry_cli.DockerArchive,
  )
  let tar = bundle.files[0].1
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
test "docker-archive reports broken zstd layers" {
  let source = sample_image(gzip=false)
  let layers : Array[PulledBlob] = []
  for layer in source.layers {
    layers.push({
      ..layer,
      media_type: @oci_spec.oci_layer_zstd_media_type,
      data: b"\x28\xb5\x2f\xfd not really a zstd frame",
    })
  }
  let image : RemoteImage = { ..source, layers, }
  let error = try
    @registry_cli.package_image(image, format=@registry_cli.DockerArchive)
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
test "oci layout keeps blobs verbatim" {
  let image = sample_image()
  let bundle = @registry_cli.package_image(
    image,
    format=@registry_cli.OciLayout,
  )
  let names = bundle.files.map(fn(entry) { entry.0 })
  assert_true(names.contains("oci-layout"))
  assert_true(names.contains("index.json"))
  // 每个 blob 都按 digest 命名，config 与层一个不少
  for layer in image.layers {
    assert_true(names.contains("blobs/sha256/\{layer.digest[7:]}"))
  }
  assert_true(names.contains("blobs/sha256/\{image.config.digest[7:]}"))
  // blob 内容原样，不重算
  for entry in bundle.files {
    let (name, data) = entry
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
test "oci layout index points at the manifest blob" {
  let image = sample_image()
  let bundle = @registry_cli.package_image(
    image,
    format=@registry_cli.OciLayout,
  )
  let index_bytes = match bundle_file(bundle, "index.json") {
    Some(data) => data
    None => fail("index.json is missing")
  }
  let index_text = @encoding.decoder(UTF8).decode(index_bytes)
  let index = @oci_spec.parse_document(index_text).unwrap()
  let descriptors = match index {
    @oci_spec.IndexDoc(index) => index.manifests
    _ => fail("index.json is not an index")
  }
  assert_eq(descriptors.length(), 1)
  let digest = descriptors[0].digest
  // index 指的 manifest 必须真的在包里，否则 layout 是坏的
  assert_true(
    bundle.files.any(fn(entry) { entry.0 == "blobs/sha256/\{digest[7:]}" }),
  )
  // 有 ref.name 才让 docker load / ctr import 恢复出 tag
  assert_true(index_text.contains("org.opencontainers.image.ref.name"))
}

///|
test "format names parse both ways" {
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
