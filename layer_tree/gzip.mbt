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
/// 解压一段 raw DEFLATE 数据；`stop_at_end` 为 false 时忽略剩余输入。
pub fn inflate(data : BytesView) -> Bytes raise DecompressError {
  let reader = BitReader::new(data)
  let output = @buffer.Buffer()
  while true {
    let final_block = reader.read_bits(1) == 1
    let block_type = reader.read_bits(2)
    match block_type {
      0 => inflate_stored(reader, output)
      1 =>
        inflate_block(
          reader,
          output,
          fixed_literal_table(),
          fixed_distance_table(),
        )
      2 => {
        let (literal, distance) = read_dynamic_tables(reader)
        inflate_block(reader, output, literal, distance)
      }
      _ => raise Gzip("reserved DEFLATE block type")
    }
    if final_block {
      break
    }
  }
  output.to_bytes()
}

///|
/// stored（未压缩）块：先对齐到字节边界，再读 LEN/NLEN 与原始数据。
fn inflate_stored(
  reader : BitReader,
  output : @buffer.Buffer,
) -> Unit raise DecompressError {
  // LEN/NLEN 是对齐后的 2 字节小端字段，不能按位读，否则会把字节读串
  let header = reader.read_bytes(4)
  let length = header[0].to_int() | (header[1].to_int() << 8)
  let complement = header[2].to_int() | (header[3].to_int() << 8)
  if (length ^ complement) != 0xFFFF {
    raise Gzip("stored block length check failed")
  }
  output.write_bytes(reader.read_bytes(length))
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
fn inflate_block(
  reader : BitReader,
  output : @buffer.Buffer,
  literal : HuffmanTable,
  distance : HuffmanTable,
) -> Unit raise DecompressError {
  while true {
    let symbol = reader.read_symbol(literal)
    if symbol < 256 {
      output.write_byte(symbol.to_byte())
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
    copy_from_window(output, back, length)
  }
}

///|
/// 从已解出的输出里按距离回拷 `length` 个字节。
///
/// 距离可能小于长度（重叠拷贝），因此必须逐字节推进而不是整段复制。
fn copy_from_window(
  output : @buffer.Buffer,
  back : Int32,
  length : Int32,
) -> Unit raise DecompressError {
  let produced = output.length()
  if back <= 0 || back > produced {
    raise Gzip("distance points before the start of the output")
  }
  // 逐字节推进：`back < length` 时源区间会盖到正在写的位置，
  // 必须一边写一边读，不能整段复制。
  //
  // 读回已写内容用 `Buffer::view()`（共享底层存储的切片，O(1)），
  // **不要**用 `to_bytes()`——它是整体拷贝，每写一个字节都拷一遍，
  // 让一次解压退化成 O(n²)：真实镜像的 80MB 层会「跑起来没有任何输出」，
  // 看上去就是挂死。`view()` 每次重新取，避免 `write_byte` 扩容后视图失效。
  for index = 0; index < length; index = index + 1 {
    let source = produced - back + index
    let byte = output.view()[source]
    output.write_byte(byte)
  }
}

///|
/// gzip 解压：解析头、inflate、跳过 CRC，最后校验 CRC32 与 ISIZE。
///
/// CRC 校验放在最后统一做，因此这里只需要单次扫描就能拿到原始数据。
pub fn gzip_decompress(data : BytesView) -> Bytes raise DecompressError {
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
  let raw = inflate(deflated)
  let trailer = data.length() - 8
  let expected_crc = read_le_uint32(data, trailer)
  let expected_size = read_le_uint32(data, trailer + 4)
  if raw.length().reinterpret_as_uint() != expected_size {
    raise Gzip("uncompressed size mismatch")
  }
  if crc32(raw) != expected_crc {
    raise Gzip("CRC32 mismatch")
  }
  raw
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
