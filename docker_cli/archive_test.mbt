///|
/// docker-archive 的 `manifest.json` 能解析出 config / repoTags / layers。
test "docker archive manifest is parsed" {
  let archive = build_docker_archive(
    [
      (
        "aaaa",
        @layer_tree.build_tar([File("etc/hosts", "127.0.0.1 localhost")]),
      ),
      ("bbbb", @layer_tree.build_tar([File("etc/passwd", "root:x:0:0")])),
    ],
    repoTags=["nginx:latest", "nginx:1"],
  )
  let parsed = @docker_cli.parse_docker_archive(archive) catch {
    err => fail("archive should parse: \{err}")
  }
  assert_eq(parsed.entries.length(), 1)
  let entry = @docker_cli.primary_entry(parsed).unwrap()
  assert_eq(entry.config, "abc123.json")
  assert_eq(entry.repoTags, ["nginx:latest", "nginx:1"])
  assert_eq(entry.layers, ["aaaa/layer.tar", "bbbb/layer.tar"])
  assert_eq(entry.layer_ids, ["aaaa", "bbbb"])
}

///|
/// 缺 `manifest.json` 的 tar 报 Archive，不 panic。
test "archive without manifest is rejected" {
  let bogus = @layer_tree.build_tar([File("readme.txt", "not an image")])
  let error = try {
    @docker_cli.parse_docker_archive(bogus) |> ignore
    fail("should reject")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("manifest.json"))
}

///|
/// `manifest.json` 不是合法 JSON 时报错并说明原因。
test "archive with malformed manifest is rejected" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("manifest.json", "{not json}")
  let archive = builder.finish()
  let error = try {
    @docker_cli.parse_docker_archive(archive) |> ignore
    fail("should reject")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("not valid JSON"))
}

///|
/// `manifest.json` 指向的层不存在，拆层时必须报错而不是静默少一层。
test "extract_layers reports a missing layer" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file(
    "manifest.json", "[{\"Config\":\"c.json\",\"RepoTags\":[\"x:1\"],\"Layers\":[\"ghost/layer.tar\"]}]",
  )
  let archive = builder.finish()
  let parsed = @docker_cli.parse_docker_archive(archive) catch {
    err => fail("manifest should parse: \{err}")
  }
  let entry = @docker_cli.primary_entry(parsed).unwrap()
  let error = try {
    @docker_cli.extract_layers(archive, entry) |> ignore
    fail("should reject")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("missing layer"))
}

///|
/// 层 ID 归一：老格式 `<id>/layer.tar` 与新版 `blobs/sha256/<hex>` 都给 `<hex>`。
test "layer ids are normalized from both archive layouts" {
  assert_eq(@docker_cli.layer_id_of("aaaa/layer.tar"), "aaaa")
  assert_eq(@docker_cli.layer_id_of("blobs/sha256/deadbeef"), "deadbeef")
  assert_eq(@docker_cli.layer_id_of("/aaaa/layer.tar"), "aaaa")
}

///|
/// `manifest.json` 是合法 JSON 但不是数组（比如被写成了对象）时报错。
test "manifest that is not an array is rejected" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("manifest.json", "{\"Config\":\"c.json\"}")
  let archive = builder.finish()
  let error = try {
    @docker_cli.parse_docker_archive(archive) |> ignore
    fail("should reject")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("not an array"))
}

///|
/// 数组元素的类型不对（比如塞了字符串）时报错，不静默跳过。
test "manifest entries that are not objects are rejected" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("manifest.json", "[\"not an object\"]")
  let archive = builder.finish()
  let error = try {
    @docker_cli.parse_docker_archive(archive) |> ignore
    fail("should reject")
  } catch {
    err => err
  }
  assert_true(error.to_string().contains("not an object"))
}

///|
/// 逃逸出根的 entry（`../etc/passwd`）在解析 manifest 时被跳过，不污染查找。
test "manifest lookup skips entries that escape the root" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("../manifest.json", "[]")
  builder.add_file("manifest.json", "[]")
  let archive = builder.finish()
  let parsed = @docker_cli.parse_docker_archive(archive) catch {
    err => fail("archive should parse: \{err}")
  }
  assert_eq(parsed.entries.length(), 0)
}

///|
/// 空数组的 manifest 是合法的（`docker save` 一个都没匹配到时会有），
/// 只是没有条目。
test "an empty manifest is valid but yields no entries" {
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("manifest.json", "[]")
  let archive = builder.finish()
  let parsed = @docker_cli.parse_docker_archive(archive) catch {
    err => fail("empty manifest should parse: \{err}")
  }
  assert_eq(parsed.entries.length(), 0)
  assert_true(@docker_cli.primary_entry(parsed) is None)
}

///|
/// 三个工具的名字都覆盖到，`Show` 输出就是可执行文件名。
test "cli tool names are stable" {
  assert_eq(@docker_cli.CliTool::Docker.to_string(), "docker")
  assert_eq(@docker_cli.CliTool::Podman.to_string(), "podman")
  assert_eq(@docker_cli.CliTool::Nerdctl.to_string(), "nerdctl")
}
