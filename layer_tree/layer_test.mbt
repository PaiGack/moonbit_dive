///|
/// 构造一个覆盖常见形态的多层镜像：基础层、覆盖层、删除层。
fn sample_image() -> Array[BytesView] {
  [
    build_tar([
      Dir("bin"),
      Dir("etc"),
      Dir("lib"),
      File("bin/sh", "#!/bin/sh"),
      File("etc/passwd", "root:x:0:0"),
      File("etc/hosts", "127.0.0.1 localhost"),
      File("lib/libc.so.6", "glibc-binary"),
      Symlink("lib/libc.so", "libc.so.6"),
    ]),
    build_tar([File("etc/hosts", "127.0.0.1 localhost\n::1 localhost")]),
    build_tar([
      Whiteout("etc", "passwd"),
      File("etc/resolv.conf", "nameserver 1.1.1.1"),
    ]),
  ]
}

///|
test "apply_layers_with_diffs reports one diff per layer" {
  let layers = sample_image()
  let result = apply_layers_with_diffs(layers, media_types=[]) catch {
    err => fail("layers should apply: \{err.to_string()}")
  }
  assert_eq(result.diffs.length(), 3)
  // 第一层与空树比，只有新增
  assert_true(result.diffs[0].added.length() > 0)
  assert_true(result.diffs[0].removed.is_empty())
  assert_eq(result.diffs[0].section_name(), "L0")
  assert_eq(result.diffs[1].section_name(), "L0 -> L1")
}

///|
test "layer diff separates added, modified and removed" {
  let layers = sample_image()
  let result = apply_layers_with_diffs(layers, media_types=[]) catch {
    err => fail("layers should apply: \{err.to_string()}")
  }
  // 第二层只改了 hosts
  assert_eq(result.diffs[1].modified, ["/etc/hosts"])
  assert_true(result.diffs[1].added.is_empty())
  assert_true(result.diffs[1].removed.is_empty())
  // 第三层删了 passwd、加了 resolv.conf
  assert_eq(result.diffs[2].removed, ["/etc/passwd"])
  assert_eq(result.diffs[2].added, ["/etc/resolv.conf"])
}

///|
test "final tree reflects all layers" {
  let layers = sample_image()
  let result = apply_layers_with_diffs(layers, media_types=[]) catch {
    err => fail("layers should apply: \{err.to_string()}")
  }
  let tree = result.tree
  assert_true(tree.get("/etc/passwd") is None)
  assert_true(tree.get("/etc/resolv.conf") is Some(_))
  assert_eq(
    size_at(tree, "/etc/hosts"),
    "127.0.0.1 localhost\n::1 localhost".length(),
  )
  assert_eq(tree.layers, 3)
}

///|
test "layer stats track changes and deletions per layer" {
  let layers = sample_image()
  let result = apply_layers_with_diffs(layers, media_types=[]) catch {
    err => fail("layers should apply: \{err.to_string()}")
  }
  let stats = result.tree.layer_stats()
  assert_eq(stats.length(), 3)
  // 第三层删掉了一个条目
  assert_eq(stats[2].deleted_paths, 1)
  assert_true(stats[2].changed_bytes > 0)
  assert_eq(result.tree.stat(1).unwrap().deleted_paths, 0)
}

///|
test "deep stacks stay linear in node count" {
  // 20 层、每层新增一个文件：节点数应随层数线性增长，而不是指数复制
  let tree = FileTree::new()
  for index in 0..<20 {
    apply_layer(
      tree,
      build_tar([File("layer-\{index}.txt", "payload-\{index}")]),
      index,
    )
  }
  assert_eq(tree.layers, 20)
  assert_eq(tree.get("/layer-19.txt") is Some(_), true)
  // 20 个文件 + 根，没有为每层复制整棵树
  assert_eq(tree.size(), 20)
}

///|
test "media type drives decompression" {
  let tree = FileTree::new()
  let plain = build_tar([File("a.txt", "plain")])
  // 未压缩
  apply_layer_with_media_type(
    tree, plain, "application/vnd.oci.image.layer.v1.tar", 0,
  ) catch {
    err => fail("plain layer should apply: \{err.to_string()}")
  }
  assert_eq(size_at(tree, "/a.txt"), 5)
  // gzip
  apply_layer_with_media_type(
    tree,
    gzip_compress(build_tar([File("b.txt", "gzipped")])),
    "application/vnd.oci.image.layer.v1.tar+gzip",
    1,
  ) catch {
    err => fail("gzip layer should apply: \{err.to_string()}")
  }
  assert_eq(size_at(tree, "/b.txt"), 7)
}

///|
test "unsupported compression is reported, not silently ignored" {
  let tree = FileTree::new()
  let zstd_result = try {
    apply_layer_with_media_type(
      tree,
      build_tar([File("a", "b")]),
      "application/vnd.oci.image.layer.v1.tar+zstd",
      0,
    )
    None
  } catch {
    err => Some(err)
  }
  match zstd_result {
    Some(LayerError::Decompress(DecompressError::Unsupported(algorithm))) =>
      assert_eq(algorithm, "zstd")
    _ => fail("expected an unsupported compression error")
  }
}

///|
test "compression_of maps layer media types" {
  assert_eq(compression_of("application/vnd.oci.image.layer.v1.tar"), "none")
  assert_eq(
    compression_of("application/vnd.oci.image.layer.v1.tar+gzip"),
    "gzip",
  )
  assert_eq(
    compression_of("application/vnd.oci.image.layer.v1.tar+zstd"),
    "zstd",
  )
  assert_eq(
    compression_of("application/vnd.docker.image.rootfs.diff.tar.gzip"),
    "gzip",
  )
}

///|
test "gzip decompression round-trips arbitrary payloads" {
  for
    payload in [
      b"", b"a", b"a longer payload with repetition repetition", b"\x00\x01\x02\xff",
    ] {
    let restored = gzip_decompress(gzip_compress(payload)) catch {
      err => fail("gzip round trip failed: \{err.to_string()}")
    }
    assert_eq(restored.length(), payload.length())
  }
}

///|
test "gzip rejects a corrupted stream" {
  let compressed = gzip_compress(b"payload")
  // 改掉 CRC32 的最后一个字节（trailer 8 字节的前 4 字节），应当被发现
  let bytes : Array[Byte] = []
  for byte in compressed {
    bytes.push(byte)
  }
  bytes[bytes.length() - 5] = bytes[bytes.length() - 5] ^ b'\xff'
  let corrupted = Bytes::from_array(bytes)
  let result = try {
    ignore(gzip_decompress(corrupted))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(DecompressError::Gzip(_)) => ()
    _ => fail("expected a gzip error for corrupted input")
  }
}
