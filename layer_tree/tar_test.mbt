///|
/// 把字节按 UTF-8 还原成字符串，供断言比较。
fn text_of(data : BytesView) -> String {
  @encoding.decoder(UTF8).decode_lossy(data)
}

///|
test "TarBuilder round-trips a single regular file" {
  let archive = build_tar([File("hello.txt", "hello world")])
  let entries = parse_tar_entries(archive) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries.length(), 1)
  let entry = entries[0]
  assert_eq(entry.path, "hello.txt")
  assert_eq(entry.entry_type, TarEntryType::Regular)
  assert_eq(entry.size, 11)
  assert_eq(text_of(entry.data(archive)), "hello world")
}

///|
test "tar parser reads directories, symlinks and hardlinks" {
  let archive = build_tar([
    Dir("etc"),
    File("etc/config", "x=1"),
    Symlink("etc/current", "config"),
    Hardlink("etc/copy", "config"),
  ])
  let entries = parse_tar_entries(archive) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries.length(), 4)
  assert_eq(entries[0].entry_type, TarEntryType::Directory)
  assert_eq(entries[1].entry_type, TarEntryType::Regular)
  assert_eq(entries[2].entry_type, TarEntryType::Symlink)
  assert_eq(entries[2].link_target, "config")
  assert_eq(entries[3].entry_type, TarEntryType::Hardlink)
  assert_eq(entries[3].link_target, "config")
}

///|
test "tar parser handles unaligned payloads and multi-block files" {
  let long = "0123456789".repeat(120)
  let archive = build_tar([File("a", "x"), File("big", long), File("b", "y")])
  let entries = parse_tar_entries(archive) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries.length(), 3)
  assert_eq(entries[1].size, 1200)
  assert_eq(text_of(entries[1].data(archive)), long)
  assert_eq(entries[2].path, "b")
  assert_eq(text_of(entries[2].data(archive)), "y")
}

///|
test "ustar prefix field carries long paths" {
  let path = "/very/long/directory/chain/that/exceeds/the/one/hundred/byte/name/field/limit/file.txt"
  let archive = build_tar([File(path, "deep")])
  let entries = parse_tar_entries(archive) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, path)
  assert_eq(text_of(entries[0].data(archive)), "deep")
}

///|
test "tar parser treats a truncated stream as an error" {
  let archive = build_tar([File("a.txt", "payload")])
  let truncated = archive[:20]
  let truncated_result = try parse_tar_entries(truncated) catch {
    e => Err(e)
  } noraise {
    entries => Ok(entries)
  }
  assert_true(truncated_result is Err(_))
}

///|
test "tar parser skips pax and GNU metadata entries" {
  let builder = TarBuilder::new()
  builder.add_header("pax-header", 0, entry_type=b'x')
  builder.add_file("real.txt", "content")
  let archive = builder.finish()
  let entries = parse_tar_entries(archive) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].entry_type, TarEntryType::Meta)
  assert_eq(entries[1].path, "real.txt")
}

///|
test "tar reader exposes data offsets into the original stream" {
  let archive = build_tar([File("a.txt", "0123456789")])
  let reader = TarReader::new(archive)
  let entry = reader.next() catch { _ => fail("expected an entry") }
  let data = entry.data(archive)
  assert_eq(data.length(), 10)
  assert_eq(data[0], b'0')
  // 到底了：第二次取应当抛 `NotFound`（这就是循环出口）
  let exhausted = try reader.next() catch {
    err => err
  } noraise {
    _ => abort("expected end of stream")
  }
  assert_true(exhausted is NotFound)
}

///|
test "entries with a ustar prefix are joined back into one path" {
  let path = "/very/long/directory/chain/that/exceeds/the/one/hundred/byte/name/field/limit/file.txt"
  let archive = build_tar([File(path, "deep")])
  let entries = parse_tar_entries(archive) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, path)
}

///|
test "directory entries do not carry payload bytes" {
  // 个别打包器会给目录 entry 写非零 size，解析侧统一当 0 处理
  let builder = TarBuilder::new()
  // 目录 entry 声称有 5 字节数据；解析侧应当忽略这个 size
  builder.add_header("weird/", 5, entry_type=b'5')
  builder.add_file("after.txt", "next")
  let entries = parse_tar_entries(builder.finish()) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries[0].entry_type, TarEntryType::Directory)
  assert_eq(entries[0].size, 0)
  assert_eq(entries[1].path, "after.txt")
}

///|
test "a half-written header block is reported as truncated" {
  // 只有 100 字节、且非全零：明确是截断而不是归档结束
  let broken : Bytes = Bytes::from_array([
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  ])
  let result = try {
    ignore(parse_tar_entries(broken))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(TarError::Truncated(_)) => ()
    _ => fail("expected a truncated error")
  }
}

///|
test "read_file_from_tar pulls a single entry without scanning twice" {
  let archive = build_tar([
    File("a.txt", "first"),
    File("b.txt", "second"),
    File("c.txt", "third"),
  ])
  let content = read_file_from_tar(archive, "b.txt") catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(text_of(content.unwrap()), "second")
  let missing = read_file_from_tar(archive, "nope.txt") catch {
    _ => fail("expected a valid tar archive")
  }
  assert_true(missing is None)
}

///|
test "TarReader exposes the declared mode and mtime" {
  let builder = TarBuilder::new()
  builder.add_header("run.sh", 0, entry_type=b'0', mode=0o700, mtime=1700000000)
  let entries = parse_tar_entries(builder.finish()) catch {
    _ => fail("expected a valid tar archive")
  }
  assert_eq(entries[0].mode, 0o700)
  assert_eq(entries[0].mtime, 1700000000)
}
