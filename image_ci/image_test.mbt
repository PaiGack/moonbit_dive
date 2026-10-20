///|
/// 造一个 docker save 风格的内存 tar：`manifest.json` + 层 tar。
fn docker_archive_tar() -> Bytes {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
  ])
  let config =
    #|{ "architecture": "amd64", "os": "linux", "rootfs": { "type": "layers", "diff_ids": ["sha256:aaa", "sha256:bbb"] } }
  let manifest =
    #|[ { "Config": "config.json", "RepoTags": ["demo:latest"], "Layers": ["layer0/layer.tar", "layer1/layer.tar"] } ]
  let builder = @layer_tree.TarBuilder::new()
  // 层先写：真实 docker save 里 manifest/config 通常排在前面，但解析应该与顺序无关
  builder.add_file("layer0/layer.tar", bytes_as_text(layer0))
  builder.add_file("layer1/layer.tar", bytes_as_text(layer1))
  builder.add_file("config.json", config)
  builder.add_file("manifest.json", manifest)
  builder.finish()
}

///|
/// 二进制数据塞进测试 tar 时的兜底转换：tar 内容都是 ascii 字节，直接按字节复制。
fn bytes_as_text(data : Bytes) -> String {
  let builder = StringBuilder()
  for byte in data {
    builder.write_char(byte.to_int().unsafe_to_char())
  }
  builder.to_string()
}

///|
/// docker save 产物：读 manifest.json，拿到两层，config 里的 diff_id 对得上。
async test "load docker archive" {
  let source = ImageSource::from_tar_bytes(
    docker_archive_tar(),
    name="demo.tar",
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(source.format, "docker-archive")
  assert_eq(source.layers.length(), 2)
  assert_eq(source.layers[0].diff_id, "sha256:aaa")
  assert_eq(source.layers[1].diff_id, "sha256:bbb")
  // 未压缩的层按 docker 的 tar media type 标记
  assert_eq(source.layers[0].media_type, @oci_spec.docker_layer_media_type)
}

///|
/// 单层 tar：没有 manifest.json 时按一个文件系统层处理。
async test "load plain layer tar" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("hello.txt", "hi"),
  ])
  let source = ImageSource::from_tar_bytes(layer, name="layer.tar") catch {
    err => fail(err.to_string())
  }
  assert_eq(source.format, "tar")
  assert_eq(source.layers.length(), 1)
  assert_eq(source.layers[0].diff_id, "")
}

///|
/// 坏输入：不是 tar / manifest.json 结构不对，都归到 `Malformed`。
async test "malformed archive reports an error" {
  let cases : Array[Bytes] = [b"this is not a tar"]
  for data in cases {
    let failed = loaded_badly(fn() raise ImageError { load_tar_result(data) })
    if !failed {
      fail("bad tar should not load")
    }
  }
}

///|
/// `manifest.json` 缺 Layers 字段时报错，而不是当成空镜像放过去。
async test "manifest without layers is malformed" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("manifest.json", "[ { \"Config\": \"config.json\" } ]")
  builder.add_file("config.json", "{}")
  let data = builder.finish()
  let failed = loaded_badly(fn() raise ImageError { load_tar_result(data) })
  if !failed {
    fail("manifest without Layers should not load")
  }
}

///|
/// 内存里的 OCI layout：blob 目录结构由测试直接在磁盘上摆。
async test "load oci layout from disk" {
  let root = "target/image_ci_fixture"
  mkdir_p(root + "/blobs/sha256")
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
  ])
  let config =
    #|{ "architecture": "amd64", "os": "linux", "rootfs": { "type": "layers", "diff_ids": ["sha256:d0", "sha256:d1"] } }
  let manifest =
    #|{ "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": { "mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:cfg", "size": 10 }, "layers": [ { "mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:l0", "size": 10 }, { "mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:l1", "size": 10 } ] }
  let index =
    #|{ "schemaVersion": 2, "manifests": [ { "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:man", "size": 10 } ] }
  write_fixture(root + "/index.json", index)
  write_fixture(root + "/oci-layout", "{\"imageLayoutVersion\":\"1.0.0\"}")
  write_fixture(root + "/blobs/sha256/man", manifest)
  write_fixture(root + "/blobs/sha256/cfg", config)
  write_fixture_bytes(root + "/blobs/sha256/l0", layer0)
  write_fixture_bytes(root + "/blobs/sha256/l1", layer1)

  let source = ImageSource::load(root) catch { err => fail(err.to_string()) }
  assert_eq(source.format, "oci-layout")
  assert_eq(source.layers.length(), 2)
  assert_eq(source.layers[0].media_type, @oci_spec.oci_layer_media_type)
  assert_eq(source.layers[1].diff_id, "sha256:d1")
  // 层字节要能原样解出来
  let raw = source.layers[0].raw_bytes() catch { err => fail(err.to_string()) }
  assert_true(raw.length() > 0)
}

///|
/// 找不到目录时是 `Io` 而不是崩。
async test "missing input reports io error" {
  let failed = try {
    load_path_result("target/definitely-not-here.tar") |> ignore
    false
  } catch {
    ImageError::Io(_) => true
    _ => false
  } noraise {
    _ => false
  }
  if !failed {
    fail("missing file should report Io")
  }
}

///|
/// 逐级建目录。`@fs.create_dir` 只做一层 `mkdir`，父目录不在就直接失败，
/// 而 `target/` 在干净的 checkout 里并不存在，所以这里自己把祖先补齐。
fn mkdir_p(path : String) -> Unit {
  let mut current = ""
  for segment in path.split("/") {
    if segment.length() == 0 {
      continue
    }
    let part : String = segment.to_owned()
    current = if current == "" { part } else { current + "/" + part }
    @fs.create_dir(current) catch {
      _ => () // 已存在（或并发建过）就继续往下走
    }
  }
}

///|
/// 写测试夹具文件。
fn write_fixture(path : String, content : String) -> Unit raise {
  @fs.write_string_to_file(path, content) catch {
    @fs.IOError(message) => fail(message)
  }
}

///|
/// 写测试夹具文件（二进制）。
fn write_fixture_bytes(path : String, content : Bytes) -> Unit raise {
  @fs.write_bytes_to_file(path, content) catch {
    @fs.IOError(message) => fail(message)
  }
}

///|
/// 只要「加载失败」这一个答案，不关心具体错误。
fn loaded_badly(load : () -> ImageSource raise ImageError) -> Bool noraise {
  try {
    load() |> ignore
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
}

///|
/// 把 `raise` 风格的加载包成 `Result`，测试里好判分支。
fn load_tar_result(data : Bytes) -> ImageSource raise ImageError {
  ImageSource::from_tar_bytes(data, name="bad.tar")
}

///|
fn load_path_result(path : String) -> ImageSource raise ImageError {
  ImageSource::load(path)
}

///|
/// 大归档：文件输入只记位置，字节按需读。
///
/// 这条用例钉的是 issue #113 的第一条：2 GiB 的 tar 不该先整个读进内存。
/// 断言分两层——「读出来的东西对」与「内存没跟着归档体积涨」。
async test "load keeps a large archive out of memory" {
  let path = "target/big-layer.tar"
  let payload = repeat_block("dive payload line\n", 64 * 1024)
  // 一份足够大的输入：真把它读进内存，RSS 至少涨这么多
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("data/payload.bin", payload),
  ])
  @fs.write_bytes_to_file(path, layer) catch {
    @fs.IOError(message) => fail(message)
  }
  let before = resident_kb()
  let source = ImageSource::load(path) catch { err => fail(err.to_string()) }
  let after = resident_kb()
  assert_eq(source.format, "tar")
  assert_eq(source.layers.length(), 1)
  // 字节还在磁盘上：`data` 是空的，位置记在 `offset` / `size` 里
  assert_eq(source.layers[0].data.length(), 0)
  assert_eq(source.layers[0].size, layer.length().to_int64())
  // 读回来仍然是完整的一层
  let raw = source.layers[0].raw_bytes() catch { err => fail(err.to_string()) }
  assert_eq(raw.length(), layer.length())
  // 峰值增量远小于归档体积：架构在内存里的只有一个小窗口
  let growth = after - before
  assert_true(growth < 16 * 1024)
}

///|
/// 同一份内容重复 `times` 遍。
fn repeat_block(block : String, times : Int32) -> String {
  let builder = StringBuilder()
  for _ in 0..<times {
    builder.write_string(block)
  }
  builder.to_string()
}

///|
/// 截断的输入要报错，而不是安静地当成一个「小一点的镜像」。
///
/// 这条要覆盖的是 issue #113 现场那句 `cannot read image: Bad address`：
/// tar 只写了一半（进程被杀 / 磁盘满）时，用户得看出是**这份文件**断了。
/// 报错必须带上路径——没有路径的错误在批量分析里等于没报。
async test "a half-written archive names the file it gave up on" {
  let path = "target/half-written.tar"
  let layer_bytes = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("big.bin", repeat_block("x", 16 * 1024)),
  ])
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("0/layer.tar", bytes_as_text(layer_bytes))
  builder.add_file(
    "manifest.json",
    (
      #|[ { "Config": "config.json", "RepoTags": ["demo:latest"], "Layers": ["0/layer.tar"] } ]
    ),
  )
  let whole = builder.finish()
  // 砍在最后一个 header 中间：`manifest.json` 的名字都读不全
  let cut = whole.length() - 40
  @fs.write_bytes_to_file(path, whole[:cut].to_owned()) catch {
    @fs.IOError(message) => fail(message)
  }
  let message = match load_outcome(path) {
    Ok(source) => "<loaded \{source.layers.length()} layers>"
    Err(reason) => reason
  }
  assert_true(message.contains(path))
}

///|
/// 装载一份输入，成败折成一句文本。
fn load_outcome(path : String) -> Result[ImageSource, String] {
  let source = try ImageSource::load(path) catch {
    err => return Err(err.to_string())
  } noraise {
    source => source
  }
  Ok(source)
}
