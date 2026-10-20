///|
/// 一段字节做成「按偏移读」的 `MappedReader`。
///
/// 与 `ImageSource::load` 走同一个解析器：只有 header 与真正要读的那段会被碰，
/// 2 GiB 的归档因此不必先整个读进内存（issue #113）。
fn mapped_over(data : Bytes) -> MappedReader {
  MappedReader::new(length=data.length().to_int64(), read_at=fn(
    position,
    length,
  ) noraise {
    let start = position.to_int()
    let end = start + length
    let real_end = if end > data.length() { data.length() } else { end }
    if start >= real_end {
      Bytes::make(0, b'\x00')
    } else {
      data[start:real_end].to_owned()
    }
  })
}

///|
/// 按需读与整段解析必须给出一模一样的结果：同一份字节、两套「怎么拿到」，
/// 解析规则只有一份（`parse_header_bytes`）。
async test "mapped reader agrees with the in-memory parser" {
  let data = build_tar([
    TarEntrySpec::Dir("app"),
    TarEntrySpec::File("app/main.js", "0123456789"),
    TarEntrySpec::Dir("empty"),
  ])
  let from_disk = parse_tar_entries_from(mapped_over(data)) catch {
    err => fail("mapped: \{err.to_string()}")
  }
  let from_memory = parse_tar_entries(data) catch {
    err => fail("in memory: \{err.to_string()}")
  }
  assert_eq(from_disk.length(), from_memory.length())
  for index, entry in from_disk {
    assert_eq(entry.path, from_memory[index].path)
    assert_eq(entry.size, from_memory[index].size)
    assert_eq(entry.data_offset_64, from_memory[index].data_offset_64)
  }
}

///|
/// 文件被截断时，按需读要报「截断」并说清位置，而不是默默返回空列表。
///
/// 两种截断都要覆盖：砍在 header 中间（512 字节都不够）与砍在数据段中间
/// （header 说 1 MiB，文件里只剩几百字节）。后者在真实场景里就是
/// 「tar 写了一半进程被杀」——读回来必须是一句人话，不是一个空包。
async test "mapped reader reports a truncated archive" {
  let header_only = build_tar([TarEntrySpec::File("app/main.js", "0123456789")])
  // 501 字节：连一个 header 都凑不齐，而且剩下的不是全零
  let cut_header = try {
    parse_tar_entries_from(mapped_over(header_only[:501].to_owned())) |> ignore
    false
  } catch {
    TarError::Truncated(_) => true
    _ => false
  } noraise {
    _ => false
  }
  assert_true(cut_header)

  // 数据段被砍：header 声明了 1 MiB，文件里只有它后面的 8 字节
  let big = build_tar([
    TarEntrySpec::File("big.bin", repeat_char('x', 1024 * 1024)),
  ])
  let cut_data = try {
    let reader = mapped_over(big[:520].to_owned())
    reader.read_exactly(512L, 1024 * 1024) |> ignore
    false
  } catch {
    TarError::Truncated(_) => true
    _ => false
  } noraise {
    _ => false
  }
  assert_true(cut_data)
}

///|
fn repeat_char(char : Char, times : Int32) -> String {
  let builder = StringBuilder()
  for _ in 0..<times {
    builder.write_char(char)
  }
  builder.to_string()
}

///|
/// 缓存的边界：连着读同一窗口内的两段，第二次不能再问一次底层。
async test "mapped reader keeps a window" {
  let data = build_tar([
    TarEntrySpec::File("a.txt", "hello"),
    TarEntrySpec::File("b.txt", "world"),
  ])
  let calls : Ref[Int32] = Ref(0)
  let reader = MappedReader::new(length=data.length().to_int64(), read_at=fn(
    position,
    length,
  ) noraise {
    calls.val = calls.val + 1
    let start = position.to_int()
    let end = start + length
    let real_end = if end > data.length() { data.length() } else { end }
    data[start:real_end].to_owned()
  })
  let first = reader.read_some(0L, 512)
  let second = reader.read_some(0L, 512)
  assert_eq(first.length(), 512)
  assert_eq(second.length(), 512)
  // 一次底层读就够：两个 header 都在同一个 64 KiB 窗口里
  assert_eq(calls.val, 1)
}
