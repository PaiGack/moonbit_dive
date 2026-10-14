///|
/// tar 块大小：每个 header 与数据段都按 512 字节对齐。
pub let tar_block_size : Int32 = 512

///|
/// ustar name 字段宽度（含 NUL）。
let tar_name_field_size : Int32 = 100

///|
/// ustar prefix 字段宽度（含 NUL）。
let tar_prefix_field_size : Int32 = 155

///|
/// tar entry 类型标志。只保留文件树关心的几种，
/// 其余（FIFO / 设备 / GNU long name 等）统一落到 `Other`。
pub(all) enum TarEntryType {
  Regular
  Directory
  Symlink
  Hardlink
  /// GNU long name / long link、pax 扩展头等元数据 entry
  Meta
  Other(Byte)
} derive(Eq, Debug)

///|
pub extend TarEntryType with Eq::{equal, not_equal}

///|
pub extend TarEntryType with @debug.Debug::{to_repr}

///|
pub impl Show for TarEntryType with fn to_string(self) {
  match self {
    Regular => "regular"
    Directory => "directory"
    Symlink => "symlink"
    Hardlink => "hardlink"
    Meta => "meta"
    Other(byte) => "other(0x\{byte.to_hex()})"
  }
}

///|
pub extend TarEntryType with Show::{to_string, output}

///|
/// 一条 tar entry 的元数据。数据不在此结构中：需要时才用
/// `TarEntry::data` 从原始流里按偏移取。
pub(all) struct TarEntry {
  /// `prefix/name` 拼出的完整路径
  path : String
  entry_type : TarEntryType
  size : Int32
  mode : Int32
  mtime : Int32
  /// 软/硬链接目标；非链接为空串
  link_target : String
  /// 数据段在流中的偏移
  data_offset : Int32
} derive(Eq, Debug)

///|
pub extend TarEntry with Eq::{equal, not_equal}

///|
pub extend TarEntry with @debug.Debug::{to_repr}

///|
pub impl Show for TarEntry with fn to_string(self) {
  let suffix = match self.entry_type {
    Symlink | Hardlink => " -> \{self.link_target}"
    _ => ""
  }
  "\{self.entry_type} \{self.path} (\{self.size} bytes)\{suffix}"
}

///|
pub extend TarEntry with Show::{to_string, output}

///|
/// 从流里取出 entry 的数据段；调用方需保证 offset/size 来自解析结果。
pub fn TarEntry::data(self : TarEntry, stream : BytesView) -> BytesView {
  stream[self.data_offset:self.data_offset + self.size]
}

///|
/// 每 512 字节对齐后的位置。
fn align_block(offset : Int32) -> Int32 {
  (offset + tar_block_size - 1) / tar_block_size * tar_block_size
}

///|
/// 判定一个 512 字节块是否是全零结束块。
fn is_zero_block(stream : BytesView, offset : Int32) -> Bool {
  let mut index = 0
  while index < tar_block_size {
    if stream[offset + index] != b'\x00' {
      return false
    }
    index = index + 1
  }
  true
}

///|
/// 复制 header 里的定长字段并去掉尾部 NUL / 空白。
fn header_string(stream : BytesView, offset : Int32, length : Int32) -> String {
  let mut end = 0
  while end < length && stream[offset + end] != b'\x00' {
    end = end + 1
  }
  @encoding.decoder(UTF8).decode_lossy(stream[offset:offset + end])
}

///|
/// 读取 header 末尾的类型标志，空字节按 ustar 惯例视为常规文件。
fn entry_type_of(byte : Byte) -> TarEntryType {
  match byte {
    b'0' | b'\x00' => Regular
    b'5' => Directory
    b'2' => Symlink
    b'1' => Hardlink
    b'x' | b'g' | b'L' | b'K' => Meta
    other => Other(other)
  }
}

///|
/// 解析八进制数字段（如 size / mode）。
///
/// 兼容记录头前导空格、以及 GNU/POSIX base-256 编码（最高位为 1）：
/// 后者用于超过八进制字段上限的大文件，把它按补码还原成非负整数。
fn parse_octal(
  stream : BytesView,
  offset : Int32,
  length : Int32,
  field : String,
) -> Int32 raise TarError {
  if (stream[offset] & b'\x80') != b'\x00' {
    return parse_base256(stream, offset, length, field)
  }
  let mut value = 0
  let mut index = 0
  while index < length {
    let byte = stream[offset + index]
    if byte == b'\x00' || byte == b' ' {
      index = index + 1
      continue
    }
    if byte < b'0' || byte > b'7' {
      raise InvalidNumber(
        field,
        @encoding.decoder(UTF8).decode_lossy(stream[offset:offset + length]),
      )
    }
    value = value * 8 + (byte - b'0').to_int()
    index = index + 1
  }
  value
}

///|
/// GNU base-256 数字段：末字节最低位为符号位，无符号场景下它就是普通位。
fn parse_base256(
  stream : BytesView,
  offset : Int32,
  length : Int32,
  field : String,
) -> Int32 raise TarError {
  let mut value = 0
  let mut index = 0
  while index < length {
    let byte = stream[offset + index]
    let digit = if index == 0 {
      // 最高字节的最高位是标记位，把它清掉再参与计数
      (byte & b'\x7f').to_int()
    } else {
      byte.to_int()
    }
    value = value * 256 + digit
    index = index + 1
  }
  if value < 0 {
    raise InvalidNumber(field, "base-256 value overflows")
  }
  value
}

///|
/// 从一块 tar 流里解析 header，返回 entry 与下一个 header 的偏移。
///
/// `absolute_offset` 用于把数据偏移换算回整段流的位置。
fn parse_header(
  stream : BytesView,
  header_offset : Int32,
  absolute_offset : Int32,
) -> TarEntry? raise TarError {
  if header_offset + tar_block_size > stream.length() {
    if is_zero_block_padded(stream, header_offset) {
      return None
    }
    raise Truncated("header block is shorter than 512 bytes")
  }
  if is_zero_block(stream, header_offset) {
    return None
  }
  let name = header_string(stream, header_offset, tar_name_field_size)
  let prefix = header_string(stream, header_offset + 345, tar_prefix_field_size)
  let mode = parse_octal(stream, header_offset + 100, 8, "mode")
  let declared_size = parse_octal(stream, header_offset + 124, 12, "size")
  let mtime = parse_octal(stream, header_offset + 136, 12, "mtime")
  let type_byte = stream[header_offset + 156]
  let entry_type = entry_type_of(type_byte)
  let link_target = if entry_type is Symlink || entry_type is Hardlink {
    header_string(stream, header_offset + 157, tar_name_field_size)
  } else {
    ""
  }
  // 目录 entry 不携带数据，但个别打包器会写非零 size；统一按 0 处理
  let size = if entry_type is Directory { 0 } else { declared_size }
  let data_offset = header_offset + tar_block_size
  if data_offset + size > stream.length() {
    raise Truncated(
      "entry \"\{name}\" declares \{size} bytes but the stream ends early",
    )
  }
  let path = if prefix.is_empty() { name } else { "\{prefix}/\{name}" }
  Some({
    path,
    entry_type,
    size,
    mode,
    mtime,
    link_target,
    data_offset: absolute_offset + data_offset,
  })
}

///|
/// 流末尾不足一个 block 时：允许整段留白，拒绝半截 header。
fn is_zero_block_padded(stream : BytesView, offset : Int32) -> Bool {
  let mut index = offset
  while index < stream.length() {
    if stream[index] != b'\x00' {
      return false
    }
    index = index + 1
  }
  true
}

///|
/// 一块 tar 流的解析器：按 entry 顺序流式推进，不把整包数据展开成对象。
///
/// `base_offset` 让调用方在「已解压的前缀 + 原始流的尾巴」上解析，
/// gzip 之外的压缩格式可借此复用同一套逻辑。
pub struct TarReader {
  stream : BytesView
  base_offset : Int32
  mut cursor : Int32
  mut done : Bool
} derive(Debug)

///|
pub extend TarReader with @debug.Debug::{to_repr}

///|
/// 在整段已解压数据上建解析器。
pub fn TarReader::new(stream : BytesView) -> TarReader {
  { stream, base_offset: 0, cursor: 0, done: false, }
}

///|
/// 在已知绝对偏移的片段上建解析器，数据偏移直接落到原始流坐标。
pub fn TarReader::with_base(
  stream : BytesView,
  base_offset : Int32,
) -> TarReader {
  { stream, base_offset, cursor: 0, done: false, }
}

///|
/// 取下一条 entry；流已到底返回 `None`。
pub fn TarReader::next(self : TarReader) -> TarEntry? raise TarError {
  if self.done {
    return None
  }
  match parse_header(self.stream, self.cursor, self.base_offset) {
    None => {
      self.done = true
      None
    }
    Some(entry) => {
      self.cursor = align_block(
        entry.data_offset - self.base_offset + entry.size,
      )
      Some(entry)
    }
  }
}

///|
/// 把整个流解析成 entry 列表。
///
/// 用于测试与需要随机访问的场合；大镜像请直接用 `TarReader`。
pub fn parse_tar_entries(stream : BytesView) -> Array[TarEntry] raise TarError {
  let reader = TarReader::new(stream)
  let entries = []
  while true {
    match reader.next() {
      None => break
      Some(entry) => entries.push(entry)
    }
  }
  entries
}

///|
/// 从 tar 流里取一条路径的数据；不存在返回 `None`。
pub fn read_file_from_tar(
  stream : BytesView,
  path : String,
) -> BytesView? raise TarError {
  let reader = TarReader::new(stream)
  while true {
    match reader.next() {
      None => break
      Some(entry) =>
        if entry.path == path && entry.entry_type is Regular {
          return Some(entry.data(stream))
        }
    }
  }
  None
}
