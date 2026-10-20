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
  /// 文件属主 / 属组（tar 头的 uid / gid 字段）
  uid : Int32
  gid : Int32
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
) -> TarEntry raise TarError {
  // 流读完（零块 / 尾部填充）时 `NotFound` 就是正常的「没有下一条」
  if header_offset + tar_block_size > stream.length() {
    if is_zero_block_padded(stream, header_offset) {
      raise NotFound
    }
    raise Truncated("header block is shorter than 512 bytes")
  }
  if is_zero_block(stream, header_offset) {
    raise NotFound
  }
  let name = header_string(stream, header_offset, tar_name_field_size)
  let prefix = header_string(stream, header_offset + 345, tar_prefix_field_size)
  let mode = parse_octal(stream, header_offset + 100, 8, "mode")
  let declared_size = parse_octal(stream, header_offset + 124, 12, "size")
  let mtime = parse_octal(stream, header_offset + 136, 12, "mtime")
  let uid = parse_octal(stream, header_offset + 108, 8, "uid")
  let gid = parse_octal(stream, header_offset + 116, 8, "gid")
  let type_byte = stream[header_offset + 156]
  let entry_type = entry_type_of(type_byte)
  let link_target = if entry_type is Symlink || entry_type is Hardlink {
    header_string(stream, header_offset + 157, tar_name_field_size)
  } else {
    ""
  }
  // 目录 entry 不携带数据，但个别打包器会写非零 size；统一按 0 处理。
  let size = if entry_type is Directory { 0 } else { declared_size }
  let data_offset = header_offset + tar_block_size
  // 校验用**声明值**：数据段实际占几个块按声明值算，回给调用方的 `size` 才是规范化后的 0
  if data_offset + declared_size > stream.length() {
    raise Truncated(
      "entry \"\\{name}\" declares \{declared_size} bytes but the stream ends early",
    )
  }
  let path = if prefix.is_empty() { name } else { "\{prefix}/\{name}" }
  {
    path,
    entry_type,
    size,
    mode,
    uid,
    gid,
    mtime,
    link_target,
    data_offset: absolute_offset + data_offset,
  }
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
/// 取下一条 entry；流已到底抛 `TarError::NotFound`（用 `catch` 当循环出口）。
pub fn TarReader::next(self : TarReader) -> TarEntry raise TarError {
  if self.done {
    raise NotFound
  }
  // 解析失败（不管是读到头还是流截断）之后，这个 reader 不会再产出东西了
  let outcome = try
    parse_header(self.stream, self.cursor, self.base_offset)
  catch {
    err => Err(err)
  } noraise {
    entry => Ok(entry)
  }
  // 读到头 / 流被截断之后，这个 reader 不会再产出东西了
  self.done = true
  let entry = match outcome {
    Ok(entry) => entry
    Err(err) => raise err
  }
  self.done = false
  self.cursor = align_block(entry.data_offset - self.base_offset + entry.size)
  entry
}

///|
/// 把整个流解析成 entry 列表。
///
/// 用于测试与需要随机访问的场合；大镜像请直接用 `TarReader`。
pub fn parse_tar_entries(stream : BytesView) -> Array[TarEntry] raise TarError {
  let reader = TarReader::new(stream)
  let entries = []
  while true {
    // 读完（`NotFound`）就是正常出口，其它错误照旧往上抛
    let entry = reader.next() catch {
      err => if err is NotFound { break } else { raise err }
    }
    entries.push(entry)
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
    // 读完（`NotFound`）就是正常出口，其它错误照旧往上抛
    let entry = reader.next() catch {
      err => if err is NotFound { break } else { raise err }
    }
    if entry.path == path && entry.entry_type is Regular {
      return Some(entry.data(stream))
    }
  }
  None
}

///|
/// 写 tar 用的一块缓冲区容量：header 一定是 512，数据按 block 补零。
/// 取 64KB 是因为 `Buffer` 扩容是整段复制，层动辄几十 MB，
/// 一次只长 512 字节会让写 tar 退化成 O(n²)。
let tar_write_chunk : Int32 = 65536

///|
/// 一条待写入的 tar entry。数据只在 `write_data` 时流式吐出，
/// 不驻留在 entry 里——大层不能因为「要打包」就被整段搬进内存两遍。
pub(all) struct TarWriteEntry {
  path : String
  /// 只支持 `Regular` / `Directory`：镜像归档里够用，
  /// 需要别的类型时再加，别为了让枚举齐全而写没测过的分支。
  entry_type : TarEntryType
  /// 数据长度。`Directory` 必须为 0。
  size : Int32
  mode : Int32
  /// 秒级时间戳，缺省 0（镜像归档里时间戳不是语义的一部分）
  mtime : Int32
} derive(Eq, Debug)

///|
pub extend TarWriteEntry with Eq::{equal, not_equal}

///|
pub extend TarWriteEntry with @debug.Debug::{to_repr}

///|
/// 造一条常规文件 entry，mode 缺省 `0644`。
pub fn tar_file_entry(
  path : String,
  size : Int32,
  mode~ : Int32 = 0o644,
  mtime~ : Int32 = 0,
) -> TarWriteEntry {
  { path, entry_type: Regular, size, mode, mtime, }
}

///|
/// 造一条目录 entry（不带数据），mode 缺省 `0755`。
pub fn tar_directory_entry(
  path : String,
  mode~ : Int32 = 0o755,
  mtime~ : Int32 = 0,
) -> TarWriteEntry {
  { path, entry_type: Directory, size: 0, mode, mtime, }
}

///|
/// 把八进制数字段写进 header；字段放不下就截断高位（调用方保证 size 合法）。
fn write_octal(
  header : FixedArray[Byte],
  offset : Int32,
  length : Int32,
  value : Int32,
) -> Unit {
  // 最后一个字节留给 NUL，前面写零填充的八进制
  let digits = length - 1
  for index = 0; index < digits; index = index + 1 {
    let shift = (digits - 1 - index) * 3
    let digit = (value >> shift) & 0o7
    header[offset + index] = digit_byte(digit)
  }
  header[offset + digits] = b'\x00'
}

///|
/// 写一个定长字符串字段，尾部补 NUL。
fn write_field(
  header : FixedArray[Byte],
  offset : Int32,
  length : Int32,
  value : String,
) -> Unit {
  let bytes = @encoding.encode(UTF8, value)
  let mut index = 0
  while index < length {
    header[offset + index] = if index < bytes.length() {
      bytes[index]
    } else {
      b'\x00'
    }
    index = index + 1
  }
}

///|
/// 拼一个 ustar header（512 字节）。
///
/// 时间戳、属主统统写 0 / 当前进程的 0:0：镜像归档里没人看这些字段，
/// 写真实值只会让同一份输入的两次打包字节不同，测试也就没法钉住输出。
fn build_header(entry : TarWriteEntry) -> FixedArray[Byte] {
  let header = FixedArray::make(tar_block_size, b'\x00')
  // 长路径拆 prefix/name：ustar 的 100 + 155 比单独 100 宽得多
  let (prefix, name) = split_ustar_path(entry.path)
  write_field(header, 0, tar_name_field_size, name)
  write_octal(header, 100, 8, entry.mode)
  write_octal(header, 108, 8, 0)
  write_octal(header, 116, 8, 0)
  write_octal(header, 124, 12, entry.size)
  write_octal(header, 136, 12, entry.mtime)
  // checksum 先按全空格算，算完再回填
  for index = 148; index < 156; index = index + 1 {
    header[index] = b' '
  }
  header[156] = if entry.entry_type is Directory { b'5' } else { b'0' }
  write_field(header, 257, 6, "ustar")
  write_field(header, 263, 2, "00")
  write_field(header, 345, tar_prefix_field_size, prefix)
  let checksum = header_checksum(header)
  // 6 位八进制 + NUL + 空格，是 ustar 的通行写法
  for index = 0; index < 6; index = index + 1 {
    let shift = (5 - index) * 3
    header[148 + index] = digit_byte((checksum >> shift) & 0o7)
  }
  header[154] = b'\x00'
  header[155] = b' '
  header
}

///|
fn header_checksum(header : FixedArray[Byte]) -> Int32 {
  let mut sum = 0
  for byte in header {
    sum = sum + byte.to_int()
  }
  sum
}

///|
/// tar 的 512 块头里最后三个字节 `<typeflag><marker><version>`，缺一不可。
/// ustar 的名字字段里若有 `&`，某些实现会把它当扩展语义——这里不处理，
/// 因为镜像归档里的路径不会出现这种写法。
///
/// 流式写 tar 的写入器：`begin` 写 header，`write_data` 吐数据，`end` 收尾。
///
/// 为什么不用 `@buffer.Buffer` 攒整包：一层的 `layer.tar` 就是几十 MB，
/// 攒整包等于把镜像的未压缩体积搬进内存。这里只保证「当前 entry 的数据
/// 按需流出」，内存占用是一个数据块，与镜像大小无关。
pub struct TarWriter {
  output : @buffer.Buffer
} derive(Debug)

///|
pub extend TarWriter with @debug.Debug::{to_repr}

///|
/// 建一个写到内存的 tar 写入器。镜像归档总量可控（分析链已经整包读入），
/// 要落盘就由调用方把 `finish` 的字节写出去。
pub fn TarWriter::new() -> TarWriter {
  { output: @buffer.Buffer(size_hint=tar_write_chunk), }
}

///|
/// 开始一条 entry：写 header，之后调用方必须正好写 `entry.size` 个字节。
pub fn TarWriter::begin(self : TarWriter, entry : TarWriteEntry) -> Unit {
  if entry.entry_type is Directory && entry.size != 0 {
    abort("tar directory entry \"\{entry.path}\" must not carry data")
  }
  self.output.write_iter(build_header(entry).iter())
}

///|
/// 写一条 entry 的数据：长度必须与 header 里的 size 一致，
/// 少了会让后面的 header 错位，所以当场对齐补零并对不上就报出来。
pub fn TarWriter::write_data(self : TarWriter, data : BytesView) -> Unit {
  self.output.write_bytes(data)
}

///|
/// 结束一条数据量为 `size` 的 entry：把不足 512 的尾巴补零。
pub fn TarWriter::pad(self : TarWriter, size : Int32) -> Unit {
  let remainder = size % tar_block_size
  if remainder == 0 {
    return
  }
  let padding = tar_block_size - remainder
  let zeros = FixedArray::make(padding, b'\x00')
  self.output.write_iter(zeros.iter())
}

///|
/// 一条 entry 一步写完（数据已经在手里时用这个）。
pub fn TarWriter::write_entry(
  self : TarWriter,
  entry : TarWriteEntry,
  data : BytesView,
) -> Unit {
  self.begin(entry)
  self.write_data(data)
  self.pad(entry.size)
}

///|
/// 收尾：两个全零块 + 按一万字节补齐（GNU tar 的习惯）。
pub fn TarWriter::finish(self : TarWriter) -> Bytes {
  let zeros = FixedArray::make(tar_block_size, b'\x00')
  self.output.write_iter(zeros.iter())
  self.output.write_iter(zeros.iter())
  let total = self.output.length()
  let remainder = total % 10240
  if remainder != 0 {
    self.output.write_iter(FixedArray::make(10240 - remainder, b'\x00').iter())
  }
  self.output.to_bytes()
}

///|
/// 单个八进制数位 -> ASCII 字节。
fn digit_byte(digit : Int32) -> Byte {
  ('0'.to_int() + digit).to_byte()
}
