///|
/// DEFLATE 最大码长（RFC 1951 限制码长不超过 15 位）。
let deflate_max_bits : Int32 = 15

///|
/// 单个 Huffman 码表：`counts[n]` 是长度为 n 的码字数，`symbols` 是按码长升序
/// 排列的符号表。解码时按标准做法逐位累加码值并与 `counts` 比较，
/// 算出符号下标后回查 `symbols`。
pub struct HuffmanTable {
  counts : FixedArray[Int32]
  symbols : FixedArray[Int32]
} derive(Debug)

///|
pub extend HuffmanTable with @debug.Debug::{to_repr}

///|
/// 按码长表构建码表。
fn HuffmanTable::from_lengths(lengths : Array[Int32]) -> HuffmanTable {
  let counts = FixedArray::make(deflate_max_bits + 1, 0)
  for length in lengths {
    if length > 0 {
      counts[length] = counts[length] + 1
    }
  }
  let offsets = FixedArray::make(deflate_max_bits + 2, 0)
  let mut total = 0
  for bits = 1; bits <= deflate_max_bits; bits = bits + 1 {
    offsets[bits + 1] = offsets[bits] + counts[bits]
    total = total + counts[bits]
  }
  let symbols = FixedArray::make(total, 0)
  let cursor = offsets.copy()
  for symbol = 0; symbol < lengths.length(); symbol = symbol + 1 {
    let length = lengths[symbol]
    if length > 0 {
      symbols[cursor[length]] = symbol
      cursor[length] = cursor[length] + 1
    }
  }
  { counts, symbols, }
}

///|
/// 固定码表（RFC 1951 3.2.6）：literal/length 与 distance 各一张固定码长表。
fn fixed_literal_table() -> HuffmanTable {
  let lengths = []
  for symbol = 0; symbol < 288; symbol = symbol + 1 {
    let length = if symbol <= 143 {
      8
    } else if symbol <= 255 {
      9
    } else if symbol <= 279 {
      7
    } else {
      8
    }
    lengths.push(length)
  }
  HuffmanTable::from_lengths(lengths)
}

///|
fn fixed_distance_table() -> HuffmanTable {
  let lengths = []
  for _ in 0..<32 {
    lengths.push(5)
  }
  HuffmanTable::from_lengths(lengths)
}

///|
/// 位读取器：DEFLATE 按 LSB-first 打包位序。
pub struct BitReader {
  data : BytesView
  mut byte : Int32
  mut bits : Int32
} derive(Debug)

///|
pub extend BitReader with @debug.Debug::{to_repr}

///|
fn BitReader::new(data : BytesView) -> BitReader {
  { data, byte: 0, bits: 0, }
}

///|
/// 对齐到下一个字节边界，丢弃当前字节里剩下的位。
///
/// 有两种「停在字节边界」的状态：`bits == 0`（正好消耗完上一字节）与
/// `bits == 8`（当前字节一位都还没读）。只有严格介于两者之间才需要跳过当前字节。
fn BitReader::align_byte(self : BitReader) -> Unit {
  if self.bits > 0 && self.bits < 8 {
    self.byte = self.byte + 1
  }
  self.bits = 0
}

///|
/// 直接按字节读 `count` 个字节，要求已对齐。
fn BitReader::read_bytes(
  self : BitReader,
  count : Int32,
) -> Bytes raise DecompressError {
  self.align_byte()
  if self.byte + count > self.data.length() {
    raise Gzip("compressed stream ends in the middle of a block")
  }
  let result = self.data[self.byte:self.byte + count].to_owned()
  self.byte = self.byte + count
  result
}

///|
/// 读 `count` 位（最多 16 位），返回原始数值。
///
/// DEFLATE 的位序是 LSB-first：字节内从最低位开始取，跨字节时低位字段先出现。
/// `self.bits` 记录「当前字节还剩几位没读」，因此取位位置是 `bits - 1` 的反向索引。
fn BitReader::read_bits(
  self : BitReader,
  count : Int32,
) -> Int32 raise DecompressError {
  let mut value = 0
  let mut filled = 0
  while filled < count {
    if self.bits == 0 {
      if self.byte >= self.data.length() {
        raise Gzip("compressed stream ends in the middle of a symbol")
      }
      self.bits = 8
    }
    // DEFLATE 逐位从**最低位**开始取：bits 是该字节已读位数
    let bit = 8 - self.bits
    if ((self.data[self.byte].to_int() >> bit) & 1) == 1 {
      value = value | (1 << filled)
    }
    self.bits = self.bits - 1
    filled = filled + 1
    if self.bits == 0 {
      self.byte = self.byte + 1
    }
  }
  value
}

///|
/// 用码表解一个符号：逐位扩展码值，逐层比较码字个数。
fn BitReader::read_symbol(
  self : BitReader,
  table : HuffmanTable,
) -> Int32 raise DecompressError {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  let mut bits = 1
  while bits <= deflate_max_bits {
    code = code | self.read_bits(1)
    let count = table.counts[bits]
    if code - first < count {
      return table.symbols[index - first + code]
    }
    index = index + count
    first = (first + count) << 1
    code = code << 1
    bits = bits + 1
  }
  raise Gzip("invalid Huffman code")
}

///|
/// 长度码 257..285 对应的基准长度与额外位数。
let length_base : ReadOnlyArray[Int32] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let length_extra : ReadOnlyArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// 距离码 0..29 对应的基准距离与额外位数。
let distance_base : ReadOnlyArray[Int32] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let distance_extra : ReadOnlyArray[Int32] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
/// 码长码表重排顺序（RFC 1951 3.2.7）。
let code_length_order : ReadOnlyArray[Int32] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
/// 解压一段 raw DEFLATE 数据，整段返回。
///
/// 只给「结果本来就不大」的场合用（配置、夹具、测试）。
/// 镜像层动辄几十上百 MB，解压出来再攒成一块既慢又占两倍内存，
/// 那条路请用 `inflate_to` 直接流给下游。
pub async fn inflate(data : BytesView) -> Bytes raise DecompressError {
  let sink = BytesSink::new()
  inflate_to(data, sink)
  sink.to_bytes()
}

///|
/// 解一段 raw DEFLATE 数据，边解边写给 `sink`。
///
/// 输出不驻留：这条路径只留一个 32KiB 的回拷窗口，
/// 内存占用与解压总量无关（issue #97 里解一层的 700MB 就是死在这上面）。
pub async fn inflate_to(
  data : BytesView,
  sink : &@io.Writer,
) -> Unit raise DecompressError {
  let reader = BitReader::new(data)
  let window = InflateWindow::new(sink)
  while true {
    let final_block = reader.read_bits(1) == 1
    let block_type = reader.read_bits(2)
    match block_type {
      0 => inflate_stored(reader, window)
      1 =>
        inflate_block(
          reader,
          window,
          fixed_literal_table(),
          fixed_distance_table(),
        )
      2 => {
        let (literal, distance) = read_dynamic_tables(reader)
        inflate_block(reader, window, literal, distance)
      }
      _ => raise Gzip("reserved DEFLATE block type")
    }
    if final_block {
      break
    }
  }
  window.flush() catch {
    err => raise Gzip(err.to_string())
  }
}

///|
/// 一个 DEFLATE 输出窗口：攒到一批就整块下发，同时留着最近 32KiB 供回拷。
///
/// 两件事共用同一块缓冲，因为它们描述的是同一段字节：回拷要能读到
/// 「刚写下的字节」，而那些字节正好还没发给下游。下发时只放掉前半段、
/// 尾巴原地搬回开头，于是「最近 32KiB」永远都在缓冲里，回拷不必绕圈。
///
/// **所有写入原语都是同步的**。这件事必须明说：写一个字节也过一遍 `async`
/// 边界的话，2 GiB 的输出就是十亿次挂起点——issue #113 里
/// `user 26m44s / real 27m0s` 的纯 CPU 时间就是这么烧掉的。下游的写盘
/// （`sink.write`）仍是 `async`，但那按 256 KiB 一批发生，不是按字节。
pub struct InflateWindow {
  buffer : FixedArray[Byte]
  /// `[0, length)` 是还没下发的字节，恒小于缓冲长度
  mut length : Int32
  /// 这段缓冲在整条输出流里的起点；回拷只能回退到它
  mut produced : Int64
  sink : &@io.Writer
}

///|
/// 回拷窗口：DEFLATE 的距离上限就是 32KiB，这一截必须一直留着。
let inflate_window_size : Int32 = 32768

///|
/// 下发粒度：缓冲一共 `32KiB + 256KiB`，攒满一次就写下 256KiB。
///
/// 老写法是 32KiB 一批（`sys` 只有 8 秒说明它不是瓶颈），但每批都要过一次
/// `async` 边界与一次系统调用；放大一个数量级，2 GiB 的层少掉 ~5 万次往返。
let inflate_batch_size : Int32 = 262144

///|
fn InflateWindow::new(sink : &@io.Writer) -> InflateWindow {
  {
    buffer: FixedArray::make(inflate_window_size + inflate_batch_size, b'\x00'),
    length: 0,
    produced: 0L,
    sink,
  }
}

///|
/// 缓冲里攒满就下发前面那批，尾巴（最近 32KiB）搬回开头。
async fn InflateWindow::drain(
  self : InflateWindow,
) -> Unit raise DecompressError {
  if self.length < self.buffer.length() {
    return
  }
  let bytes = self.buffer.unsafe_reinterpret_as_bytes()
  self.sink.write(bytes[:inflate_batch_size]) catch {
    err => raise Gzip(err.to_string())
  }
  self.buffer.blit_from_bytesview(0, bytes[inflate_batch_size:])
  self.length = self.length - inflate_batch_size
  self.produced = self.produced + inflate_batch_size.to_int64()
}

///|
/// 收尾：把攒着的全下发。
async fn InflateWindow::flush(
  self : InflateWindow,
) -> Unit raise DecompressError {
  if self.length > 0 {
    self.sink.write(self.buffer.unsafe_reinterpret_as_bytes()[:self.length]) catch {
      err => raise Gzip(err.to_string())
    }
    self.produced = self.produced + self.length.to_int64()
    self.length = 0
  }
}

///|
/// 写一个字节。缓冲满之前不会失败，也不需要主动做事。
///
/// 「满了」由调用方查 `full()` 后 `drain`：一次 `drain` 之后至少还有 1 MiB
/// 空间，于是写字节与它的调用点都不必是 `async`——否则每个输出字节都要过
/// 一次挂起点（2 GiB 的层就是十亿次，issue #113 的纯 CPU 时间就在这儿）。
fn InflateWindow::put_byte(self : InflateWindow, byte : Byte) -> Unit {
  self.buffer[self.length] = byte
  self.length = self.length + 1
}

///|
/// 缓冲是不是已经写满（`put_byte` 之后要查一次）。
fn InflateWindow::full(self : InflateWindow) -> Bool {
  self.length == self.buffer.length()
}

///|
/// 写一段字节（stored 块用）：能塞多少塞多少，满了 `drain` 再继续。
async fn InflateWindow::put_bytes(
  self : InflateWindow,
  data : BytesView,
) -> Unit raise DecompressError {
  let mut offset = 0
  while offset < data.length() {
    let room = self.buffer.length() - self.length
    let take = if data.length() - offset < room {
      data.length() - offset
    } else {
      room
    }
    if take > 0 {
      self.buffer.blit_from_bytesview(self.length, data[offset:offset + take])
      self.length = self.length + take
      offset = offset + take
    }
    if offset < data.length() {
      self.drain() catch {
        err => raise Gzip(err.to_string())
      }
    }
  }
}

///|
/// 回拷 `length` 个字节，源位置距当前位置 `back` 字节。
///
/// `back < length` 是常见情况（`abcabcabc...`）：后写的字节立刻成为后续读取的源，
/// 所以要从头顺着拷，不能整段 `blit`。但「顺着拷」不等于「逐字节过 async」——
/// 这里把能连续拷贝的段算出来，一段一次 `blit`，只在缓冲满时才挂起。
///
/// 距离可以越过当前攒着的范围（跨过已经下发的字节），但不能越过整条输出流的开头——
/// 那说明压缩流本身是坏的。缓冲里留着的尾巴保证「越过」这一支读得到。
async fn InflateWindow::copy_from(
  self : InflateWindow,
  back : Int32,
  length : Int32,
) -> Unit raise DecompressError {
  if back <= 0 || back.to_int64() > self.produced + self.length.to_int64() {
    raise Gzip("distance points before the start of the output")
  }
  let bytes = self.buffer.unsafe_reinterpret_as_bytes()
  let mut remaining = length
  while remaining > 0 {
    if self.length == self.buffer.length() {
      self.drain() catch {
        err => raise Gzip(err.to_string())
      }
      continue
    }
    let source = self.length - back
    if source < 0 {
      raise Gzip("distance reaches past the retained window")
    }
    let room = self.buffer.length() - self.length
    // 源与目的都从 `source` 开始、每次挪同样多，所以「源 + 一次拷贝量」
    // 不超过当前位置时，这一次拷贝读的全是拷之前就在的字节，整段 `blit`
    // 与逐字节等价。重叠的情况（比如 `abcabc`）就退成一小段一小段。
    let lag = self.length - source
    let run = if lag >= remaining && remaining <= room {
      remaining
    } else if lag >= room {
      room
    } else {
      let step = if lag < remaining { lag } else { remaining }
      if step < room {
        step
      } else {
        room
      }
    }
    self.buffer.blit_from_bytesview(self.length, bytes[source:source + run])
    self.length = self.length + run
    remaining = remaining - run
  }
}

///|
/// stored（未压缩）块：先对齐到字节边界，再读 LEN/NLEN 与原始数据。
async fn inflate_stored(
  reader : BitReader,
  window : InflateWindow,
) -> Unit raise DecompressError {
  // LEN/NLEN 是对齐后的 2 字节小端字段，不能按位读，否则会把字节读串
  let header = reader.read_bytes(4)
  let length = header[0].to_int() | (header[1].to_int() << 8)
  let complement = header[2].to_int() | (header[3].to_int() << 8)
  if (length ^ complement) != 0xFFFF {
    raise Gzip("stored block length check failed")
  }
  window.put_bytes(reader.read_bytes(length))
}

///|
/// 动态 Huffman 块：先读码长码表，再解码出 literal/length 与 distance 的码长表。
fn read_dynamic_tables(
  reader : BitReader,
) -> (HuffmanTable, HuffmanTable) raise DecompressError {
  let literal_count = reader.read_bits(5) + 257
  let distance_count = reader.read_bits(5) + 1
  let code_length_count = reader.read_bits(4) + 4
  let code_length_lengths = FixedArray::make(19, 0)
  for index = 0; index < code_length_count; index = index + 1 {
    code_length_lengths[code_length_order[index]] = reader.read_bits(3)
  }
  let code_length_table = HuffmanTable::from_lengths(
    fixed_array_to_array(code_length_lengths),
  )
  let total = literal_count + distance_count
  let lengths = FixedArray::make(total, 0)
  let mut index = 0
  while index < total {
    let symbol = reader.read_symbol(code_length_table)
    match symbol {
      0..<=15 => {
        lengths[index] = symbol
        index = index + 1
      }
      16 => {
        if index == 0 {
          raise Gzip("code length repeat with no previous length")
        }
        let previous = lengths[index - 1]
        let repeat = reader.read_bits(2) + 3
        for _ in 0..<repeat {
          if index >= total {
            raise Gzip("code length repeat overflows the table")
          }
          lengths[index] = previous
          index = index + 1
        }
      }
      17 | 18 => {
        // 17 = 重复 3 次 + 3 位额外计数，18 = 重复 11 次 + 7 位额外计数
        let (base, extra_bits) = if symbol == 17 { (3, 3) } else { (11, 7) }
        let repeat = reader.read_bits(extra_bits) + base
        for _ in 0..<repeat {
          if index >= total {
            raise Gzip("code length run overflows the table")
          }
          lengths[index] = 0
          index = index + 1
        }
      }
      _ => raise Gzip("invalid code length symbol")
    }
  }
  let literal_lengths = []
  for position = 0; position < literal_count; position = position + 1 {
    literal_lengths.push(lengths[position])
  }
  let distance_lengths = []
  for position = literal_count; position < total; position = position + 1 {
    distance_lengths.push(lengths[position])
  }
  (
    HuffmanTable::from_lengths(literal_lengths),
    HuffmanTable::from_lengths(distance_lengths),
  )
}

///|
/// 用 literal/distance 码表解一个 Huffman 压缩块，遇结束符 256 返回。
///
/// 固定码表是常量：只为一块现建一次码表，在小块多的层上是纯浪费。
async fn inflate_block(
  reader : BitReader,
  window : InflateWindow,
  literal : HuffmanTable,
  distance : HuffmanTable,
) -> Unit raise DecompressError {
  while true {
    let symbol = reader.read_symbol(literal)
    if symbol < 256 {
      window.put_byte(symbol.to_byte())
      if window.full() {
        window.drain() catch {
          err => raise Gzip(err.to_string())
        }
      }
      continue
    }
    if symbol == 256 {
      return
    }
    let length_index = symbol - 257
    if length_index < 0 || length_index >= length_base.length() {
      raise Gzip("invalid length symbol")
    }
    let length = length_base[length_index] +
      reader.read_bits(length_extra[length_index])
    let distance_symbol = reader.read_symbol(distance)
    if distance_symbol >= distance_base.length() {
      raise Gzip("invalid distance symbol")
    }
    let back = distance_base[distance_symbol] +
      reader.read_bits(distance_extra[distance_symbol])
    window.copy_from(back, length)
  }
}

///|
/// gzip 解压：解析头、inflate、跳过 CRC，最后校验 CRC32 与 ISIZE。
///
/// CRC 校验放在最后统一做，因此这里只需要单次扫描就能拿到原始数据。
pub async fn gzip_decompress(data : BytesView) -> Bytes raise DecompressError {
  let sink = BytesSink::new()
  gzip_decompress_to(data, sink)
  sink.to_bytes()
}

///|
/// gzip 解压，边解边写给 `sink`。
///
/// 与 `gzip_decompress` 的差别只有一条：解出来的字节不攒成一块。
/// 校验（ISIZE / CRC32）在最后统一做，所以调用方要在本函数返回之后
/// 才把 `sink` 里的内容当真——中途出错时已经写出去的部分是不完整的。
///
/// 这一层就是 issue #97 的现场：700MB 的层按老写法要整段落在内存里再打包，
/// 而打包本身又整段攒一遍，两倍的内存直接把缓冲区顶爆。
pub async fn gzip_decompress_to(
  data : BytesView,
  sink : &@io.Writer,
) -> Unit raise DecompressError {
  if data.length() < 18 {
    raise Gzip("stream is too short to be a gzip member")
  }
  if data[0] != b'\x1f' || data[1] != b'\x8b' {
    raise Gzip("missing gzip magic bytes")
  }
  let compression_method = data[2]
  if compression_method != b'\x08' {
    raise Gzip(
      "unsupported gzip compression method \{compression_method.to_int()}",
    )
  }
  let flags = data[3]
  let mut offset = 10
  // FEXTRA
  if (flags & b'\x04') != b'\x00' {
    let extra_length = data[offset].to_int() | (data[offset + 1].to_int() << 8)
    offset = offset + 2 + extra_length
  }
  // FNAME / FCOMMENT 都是 NUL 结尾的字符串
  if (flags & b'\x08') != b'\x00' {
    offset = skip_c_string(data, offset)
  }
  if (flags & b'\x10') != b'\x00' {
    offset = skip_c_string(data, offset)
  }
  // FHCRC：2 字节头校验
  if (flags & b'\x02') != b'\x00' {
    offset = offset + 2
  }
  if offset > data.length() - 8 {
    raise Gzip("gzip header runs past the end of the stream")
  }
  let deflated = data[offset:data.length() - 8]
  // 边解边过一遍 CRC：输出不落盘，校验也就不必再扫第二遍
  let tee = Crc32Tee::new(sink)
  inflate_to(deflated, tee)
  tee.finish()
  let trailer = data.length() - 8
  let expected_crc = read_le_uint32(data, trailer)
  let expected_size = read_le_uint32(data, trailer + 4)
  if (tee.total & 0xFFFFFFFFL).to_int().reinterpret_as_uint() != expected_size {
    raise Gzip("uncompressed size mismatch")
  }
  if tee.checksum() != expected_crc {
    raise Gzip("CRC32 mismatch")
  }
}

///|
/// 一个「转发给下游 + 顺手算 CRC32 和长度」的写入器。
///
/// gzip 的 trailer 在流的最后，而正文已经流走了；要么再扫一遍（大层上不可能），
/// 要么在写出去的同时把校验位算出来。这里选后者。
pub struct Crc32Tee {
  sink : &@io.Writer
  mut crc : UInt32
  /// 已写出的字节数；gzip 的 ISIZE 只有 32 位，比较时取低 32 位
  mut total : Int64
}

///|
fn Crc32Tee::new(sink : &@io.Writer) -> Crc32Tee {
  { sink, crc: 0xFFFFFFFFU, total: 0L, }
}

///|
pub impl @io.Writer for Crc32Tee with fn write_once(
  self : Crc32Tee,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let data = buf[offset:offset + len]
  let mut value = self.crc
  for index = 0; index < data.length(); index = index + 1 {
    value = crc32_table[(value ^ data[index].to_int().reinterpret_as_uint()).reinterpret_as_int() &
      0xFF] ^
      (value >> 8)
  }
  self.crc = value
  self.total = self.total + data.length().to_int64()
  self.sink.write(data)
  len
}

///|
pub extend Crc32Tee with @io.Writer::{write_once, write, write_reader}

///|
/// 收尾：把 CRC 取反成最终值（gzip trailer 里存的是取反后的结果）。
fn Crc32Tee::finish(self : Crc32Tee) -> Unit {
  self.crc = self.crc ^ 0xFFFFFFFFU
}

///|
/// 当前 CRC32；`finish` 之后才是最终值。
fn Crc32Tee::checksum(self : Crc32Tee) -> UInt32 {
  self.crc
}

///|
fn skip_c_string(
  data : BytesView,
  offset : Int32,
) -> Int32 raise DecompressError {
  let mut index = offset
  while index < data.length() && data[index] != b'\x00' {
    index = index + 1
  }
  if index >= data.length() {
    raise Gzip("unterminated string in gzip header")
  }
  index + 1
}

///|
fn read_le_uint32(data : BytesView, offset : Int32) -> UInt32 {
  let mut value : UInt32 = 0
  for index = 0; index < 4; index = index + 1 {
    value = value |
      (data[offset + index].to_int().reinterpret_as_uint() << (index * 8))
  }
  value
}

///|
/// CRC32（IEEE 802.3）查表实现。
let crc32_table : FixedArray[UInt32] = crc32_table_of()

///|
fn crc32_table_of() -> FixedArray[UInt32] {
  let table = FixedArray::make(256, 0U)
  for index = 0; index < 256; index = index + 1 {
    let mut value = index.reinterpret_as_uint()
    for _ in 0..<8 {
      value = if (value & 1U) == 1U {
        (value >> 1) ^ 0xEDB88320U
      } else {
        value >> 1
      }
    }
    table[index] = value
  }
  table
}

///|
/// 计算 CRC32；结果与 gzip trailer 中的字段直接可比。
pub fn crc32(data : BytesView) -> UInt32 {
  let mut value = 0xFFFFFFFFU
  for index = 0; index < data.length(); index = index + 1 {
    value = crc32_table[(value ^ data[index].to_int().reinterpret_as_uint()).reinterpret_as_int() &
      0xFF] ^
      (value >> 8)
  }
  value ^ 0xFFFFFFFFU
}

///|
/// FixedArray 转 Array 的小工具（数组只在建表时用，成本可忽略）。
fn fixed_array_to_array(values : FixedArray[Int32]) -> Array[Int32] {
  let result = []
  for value in values {
    result.push(value)
  }
  result
}

///|
/// 一个纯粹的「攒字节」写入器：给 `inflate` / `gzip_decompress` 这种
/// 「整段返回」的入口当落地端。
///
/// `@buffer.Buffer` 现在没有 `io.Writer` 实现（上游还在过渡），
/// 而流式解压必须有个写入器出口，所以这里自己实现一份最小的。
pub struct BytesSink {
  buffer : @buffer.Buffer
}

///|
fn BytesSink::new() -> BytesSink {
  { buffer: @buffer.Buffer(size_hint=64 * 1024), }
}

///|
fn BytesSink::to_bytes(self : BytesSink) -> Bytes {
  self.buffer.to_bytes()
}

///|
pub impl @io.Writer for BytesSink with fn write_once(
  self : BytesSink,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  self.buffer.write_bytes(buf[offset:offset + len])
  len
}

///|
pub extend BytesSink with @io.Writer::{write_once, write, write_reader}
