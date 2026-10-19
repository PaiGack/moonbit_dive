///|
test "tar writer roundtrip" {
  let writer = TarWriter::new()
  let data = @encoding.encode(UTF8, "hello tar writer")
  writer.write_entry(tar_directory_entry("layers"), b"")
  writer.write_entry(tar_file_entry("layers/a.txt", data.length()), data)
  let bytes = writer.finish()
  // 收尾按一万字节对齐，与 GNU tar 的产物一致
  assert_eq(bytes.length() % 10240, 0)
  let entries = parse_tar_entries(bytes)
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].path, "layers")
  assert_true(entries[0].entry_type is Directory)
  assert_eq(entries[1].path, "layers/a.txt")
  assert_eq(entries[1].size, 16)
  assert_eq(entries[1].mode, 0o644)
  let read = read_file_from_tar(bytes, "layers/a.txt").unwrap()
  assert_eq(@encoding.decoder(UTF8).decode(read), "hello tar writer")
}

///|
test "tar writer pads data to the block size" {
  let writer = TarWriter::new()
  let data = @encoding.encode(UTF8, "abc")
  writer.write_entry(tar_file_entry("a", 3), data)
  let bytes = writer.finish()
  let entries = parse_tar_entries(bytes)
  assert_eq(entries.length(), 1)
  // header(512) + 数据补齐一块(512) + 两个结束块(1024)，再补到一万字节
  assert_eq(entries[0].data(bytes).length(), 3)
}

///|
test "tar writer keeps long paths in prefix/name" {
  let deep = "aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dddddddddd/eeeeeeeeee/ffffffffff/gggggggggg/hhhhhhhhhh/iiiiiiiiii/jjjjjjjjjj/kkkkkkkkkk.txt"
  assert_true(deep.length() > 100)
  let writer = TarWriter::new()
  writer.write_entry(tar_file_entry(deep, 0), b"")
  let entries = parse_tar_entries(writer.finish())
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, deep)
}
