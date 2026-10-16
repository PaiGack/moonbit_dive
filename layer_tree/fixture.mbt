///|
/// 测试用的 tar 构造器：手工拼 header 与数据块。
///
/// 生产代码只解析 tar（镜像里的层是外部产物），写 tar 的能力只为测试服务，
/// 因此放在包内而不是公开 API 里。
pub struct TarBuilder {
  blocks : Array[Byte]
} derive(Debug)

///|
pub extend TarBuilder with @debug.Debug::{to_repr}

///|
/// 新建一个空构造器。
pub fn TarBuilder::new() -> TarBuilder {
  { blocks: [], }
}

///|
/// 追加一个 header：`path` 会被拆到 ustar 的 name / prefix 字段里。
///
/// `entry_type` 用 tar 的类型标志（`b'0'` 常规、`b'5'` 目录、`b'2'` 软链、`b'1'` 硬链）。
pub fn TarBuilder::add_header(
  self : TarBuilder,
  path : String,
  size : Int32,
  entry_type~ : Byte = b'0',
  mode~ : Int32 = 0o644,
  link_target~ : String = "",
  mtime~ : Int32 = 0,
) -> Unit {
  let header = FixedArray::make(tar_block_size, b'\x00')
  let name = path
  let name_bytes = utf8_bytes(name)
  if name_bytes.length() <= 100 && !name.has_prefix("/") {
    write_into(header, 0, name_bytes)
  } else {
    // 超长路径：从右往左找一个能放进 100 字节的前缀分界点
    let split = split_ustar_path(name)
    write_into(header, 0, utf8_bytes(split.1))
    write_into(header, 345, utf8_bytes(split.0))
  }
  // 八进制字段都以上一个 NUL 收尾：这里补足到字段边界
  write_into(header, 100, utf8_bytes(octal(mode, 7) + "\u{0}"))
  write_into(header, 108, utf8_bytes(octal(0, 7) + "\u{0}"))
  write_into(header, 116, utf8_bytes(octal(0, 7) + "\u{0}"))
  write_into(header, 124, utf8_bytes(octal(size, 11) + "\u{0}"))
  write_into(header, 136, utf8_bytes(octal(mtime, 11) + "\u{0}"))
  // 校验和字段先填空格，算完再回填
  write_into(header, 148, utf8_bytes("        "))
  header[156] = entry_type
  write_into(header, 157, utf8_bytes(link_target))
  write_into(header, 257, utf8_bytes("ustar\u{0}"))
  write_into(header, 263, utf8_bytes("00"))
  let checksum = header.fold(init=0, (acc, byte) => acc + byte.to_int())
  write_into(header, 148, utf8_bytes(octal(checksum, 6) + "\u{0} "))
  for byte in header {
    self.blocks.push(byte)
  }
}

///|
/// 追加一条内容为二进制数据的常规文件 entry。
///
/// `add_file` 收 `String`，二进制层内容（可执行文件、字体）过不去；
/// 镜象分析里「层本身也是 tar」这种嵌套场景需要字节入口。
pub fn TarBuilder::add_raw_file(
  self : TarBuilder,
  path : String,
  content : BytesView,
  mode~ : Int32 = 0o644,
) -> Unit {
  self.add_header(path, content.length(), entry_type=b'0', mode~)
  self.push_data_bytes(content)
}

///|
/// 追加一条常规文件 entry。
pub fn TarBuilder::add_file(
  self : TarBuilder,
  path : String,
  content : String,
  mode~ : Int32 = 0o644,
) -> Unit {
  let bytes = utf8_bytes(content)
  self.add_header(path, bytes.length(), entry_type=b'0', mode~)
  self.push_data(bytes)
}

///|
/// 追加一条目录 entry。
pub fn TarBuilder::add_directory(
  self : TarBuilder,
  path : String,
  mode~ : Int32 = 0o755,
) -> Unit {
  let name = if path.has_suffix("/") { path } else { path + "/" }
  self.add_header(name, 0, entry_type=b'5', mode~)
}

///|
/// 追加一条软链接 entry。
pub fn TarBuilder::add_symlink(
  self : TarBuilder,
  path : String,
  target : String,
  mode~ : Int32 = 0o777,
) -> Unit {
  self.add_header(path, 0, entry_type=b'2', mode~, link_target=target)
}

///|
/// 追加一条硬链接 entry。
pub fn TarBuilder::add_hardlink(
  self : TarBuilder,
  path : String,
  target : String,
  mode~ : Int32 = 0o644,
) -> Unit {
  self.add_header(path, 0, entry_type=b'1', mode~, link_target=target)
}

///|
/// 追加 `.wh.<name>` whiteout entry。
pub fn TarBuilder::add_whiteout(
  self : TarBuilder,
  directory : String,
  name : String,
) -> Unit {
  let path = if directory == "" || directory == "/" {
    whiteout_prefix + name
  } else {
    "\{directory}/\{whiteout_prefix}\{name}"
  }
  self.add_header(path, 0, entry_type=b'0')
}

///|
/// 追加 `.wh..wh..opq` opaque 标记。
pub fn TarBuilder::add_opaque(self : TarBuilder, directory : String) -> Unit {
  let path = if directory == "" || directory == "/" {
    opaque_marker
  } else {
    "\{directory}/\{opaque_marker}"
  }
  self.add_header(path, 0, entry_type=b'0')
}

///|
fn TarBuilder::push_data_bytes(self : TarBuilder, bytes : BytesView) -> Unit {
  for byte in bytes {
    self.blocks.push(byte)
  }
  let padding = (tar_block_size - bytes.length() % tar_block_size) %
    tar_block_size
  for _ in 0..<padding {
    self.blocks.push(b'\x00')
  }
}

///|
fn TarBuilder::push_data(self : TarBuilder, bytes : Bytes) -> Unit {
  for byte in bytes {
    self.blocks.push(byte)
  }
  let padding = (tar_block_size - bytes.length() % tar_block_size) %
    tar_block_size
  for _ in 0..<padding {
    self.blocks.push(b'\x00')
  }
}

///|
/// 收尾：补两个全零块作为归档结束标记。
pub fn TarBuilder::finish(self : TarBuilder) -> Bytes {
  for _ in 0..<(tar_block_size * 2) {
    self.blocks.push(b'\x00')
  }
  let buffer = @buffer.Buffer()
  for byte in self.blocks {
    buffer.write_byte(byte)
  }
  buffer.to_bytes()
}

///|
/// 直接构建单层 tar 数据（方便测试里一行写完）。
pub fn build_tar(entries : Array[TarEntrySpec]) -> Bytes {
  let builder = TarBuilder::new()
  for entry in entries {
    match entry {
      File(path, content) => builder.add_file(path, content)
      Dir(path) => builder.add_directory(path)
      Symlink(path, target) => builder.add_symlink(path, target)
      Hardlink(path, target) => builder.add_hardlink(path, target)
      Whiteout(dir, name) => builder.add_whiteout(dir, name)
      Opaque(dir) => builder.add_opaque(dir)
    }
  }
  builder.finish()
}

///|
/// `build_tar` 的条目规格。
pub(all) enum TarEntrySpec {
  File(String, String)
  Dir(String)
  Symlink(String, String)
  Hardlink(String, String)
  /// 目录 + 被删除的同目录条目名
  Whiteout(String, String)
  Opaque(String)
} derive(Eq, Debug)

///|
pub extend TarEntrySpec with Eq::{equal, not_equal}

///|
pub extend TarEntrySpec with @debug.Debug::{to_repr}

///|
/// 八进制字段编码：长度固定，以 NUL 结尾。
fn octal(value : Int32, digits : Int32) -> String {
  let mut text = ""
  let mut remaining = value
  for _ in 0..<digits {
    let digit = remaining % 8
    text = Int32::unsafe_to_char('0'.to_int() + digit).to_string() + text
    remaining = remaining / 8
  }
  text
}

///|
/// 把字节写进定长 header 字段，多余部分丢弃（字段截断由调用方负责）。
fn write_into(field : FixedArray[Byte], offset : Int32, bytes : Bytes) -> Unit {
  for index, byte in bytes {
    if offset + index >= field.length() {
      break
    }
    field[offset + index] = byte
  }
}

///|
/// 按 UTF-8 编码字符串。
fn utf8_bytes(text : String) -> Bytes {
  @encoding.encode(UTF8, text)
}

///|
/// ustar 的超长路径拆成 (prefix, name)：在 `/` 处从右往左切，
/// 保证两段都能放进各自的字段，同时不丢开头的根斜杠。
fn split_ustar_path(path : String) -> (String, String) {
  let mut best : (String, String)? = None
  let bytes = utf8_bytes(path)
  for split in 0..<path.length() {
    if path.code_unit_at(split) != '/' {
      continue
    }
    let prefix = path[:split].to_owned()
    // name 字段不能带前导 `/`，否则解析回来的路径会多一层
    let name = path[split + 1:].to_owned()
    if prefix.is_empty() || name.is_empty() {
      continue
    }
    if utf8_bytes(prefix).length() <= 155 && utf8_bytes(name).length() <= 100 {
      best = Some((prefix, name))
    }
  }
  ignore(bytes)
  match best {
    Some(pair) => pair
    // 没有合法切点（path 全是一段），交给 name 字段截断
    None => ("", if path.has_prefix("/") { path[1:].to_owned() } else { path })
  }
}

///|
/// 把字节压成 gzip 成员，用于测试解压路径。
///
/// 只产出 DEFLATE 的 stored（未压缩）块：gzip 容器、CRC32、ISIZE 都是真实字段，
/// 解压侧该走的校验一个不少，但不必在测试里实现压缩器。
pub fn gzip_compress(data : BytesView) -> Bytes {
  let buffer = @buffer.Buffer()
  // gzip header：magic、方法 8、标志 0、mtime 0、XFL 0、OS 255
  buffer.write_bytes(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff")
  let mut offset = 0
  // 空输入也要有一个空 stored 块，否则 gzip 成员没有 DEFLATE 数据
  if data.length() == 0 {
    buffer.write_byte(b'\x01')
    write_le_uint16(buffer, 0)
    write_le_uint16(buffer, 0xFFFF)
  } else {
    while offset < data.length() {
      let remaining = data.length() - offset
      let chunk = if remaining > 65535 { 65535 } else { remaining }
      // BFINAL + BTYPE=00；位写在字节低位，块头同样从字节边界开始
      buffer.write_byte(if chunk == remaining { b'\x01' } else { b'\x00' })
      write_le_uint16(buffer, chunk)
      write_le_uint16(buffer, chunk ^ 0xFFFF)
      buffer.write_bytes(data[offset:offset + chunk])
      offset = offset + chunk
    }
  }
  write_le_uint32(buffer, crc32(data))
  write_le_uint32(buffer, data.length().reinterpret_as_uint())
  buffer.to_bytes()
}

///|
fn write_le_uint16(buffer : @buffer.Buffer, value : Int32) -> Unit {
  buffer.write_byte((value & 0xFF).to_byte())
  buffer.write_byte(((value >> 8) & 0xFF).to_byte())
}

///|
fn write_le_uint32(buffer : @buffer.Buffer, value : UInt32) -> Unit {
  for index in 0..<4 {
    buffer.write_byte(
      ((value >> (index * 8)) & 0xFFU).reinterpret_as_int().to_byte(),
    )
  }
}
