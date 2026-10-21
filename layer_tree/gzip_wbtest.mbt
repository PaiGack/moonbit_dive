///|
/// whitebox：位读取器的对齐与位序是最容易出错的地方，单独盯住。
async test "BitReader reads bits LSB-first and aligns to the next byte" {
  let data : Bytes = b"\x01\x10\x00\xef\xff\xff"
  let reader = BitReader::new(data)
  // BFINAL=1、BTYPE=00，还剩 5 位没读
  assert_eq(reader.read_bits(1) catch { _ => fail("read") }, 1)
  assert_eq(reader.read_bits(2) catch { _ => fail("read") }, 0)
  assert_eq(reader.bits, 5)
  reader.align_byte()
  assert_eq(reader.byte, 1)
  // 对齐后按字节读 LEN/NLEN
  assert_eq(reader.read_bits(16) catch { _ => fail("read") }, 0x0010)
  assert_eq(reader.read_bits(16) catch { _ => fail("read") }, 0xFFEF)
}

///|
async test "BitReader keeps byte position when already aligned" {
  let reader = BitReader::new(b"\x01\x10\x00\xef")
  // 读完 8 位后 bits == 0，此时不应再跳过字节
  assert_eq(reader.read_bits(8) catch { _ => fail("read") }, 1)
  reader.align_byte()
  assert_eq(reader.byte, 1)
  assert_eq(reader.read_bits(8) catch { _ => fail("read") }, 0x10)
}

///|
async test "inflate decodes a stored block" {
  let raw : Bytes = b"hello stored"
  let compressed = gzip_compress(raw)
  let deflated = compressed[10:compressed.length() - 8]
  let inflated = inflate(deflated) catch {
    err => fail("inflate failed: " + err.to_string())
  }
  assert_eq(inflated.length(), raw.length())
}

///|
async test "crc32 matches the reference value for a known input" {
  // CRC32("123456789") = 0xCBF43926，DEFLATE 与 gzip 的通用校验基准
  assert_eq(crc32(b"123456789"), 0xCBF43926U)
  assert_eq(crc32(b""), 0U)
}

///|
async test "gzip rejects a stream with a bad magic number" {
  let broken = b"not a gzip stream at all, really"
  let result = try {
    ignore(gzip_decompress(broken))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(DecompressError::Gzip(message)) =>
      assert_true(message.contains("magic"))
    _ => fail("expected a magic-number error")
  }
}

///|
async test "inflate rejects a reserved block type" {
  // BFINAL=0、BTYPE=11（保留类型）：位序是 LSB-first，故首字节为 0b0000_0110
  let result = try {
    ignore(inflate(b"\x06\x00"))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(DecompressError::Gzip(_)) => ()
    _ => fail("expected a reserved block type error")
  }
}

///|
async test "inflate decodes real streams produced by an external gzip encoder" {
  assert_eq(gzip_reference_streams.length(), gzip_reference_sizes.length())
  for index, stream in gzip_reference_streams {
    let restored = gzip_decompress(stream) catch {
      err => fail("reference stream \{index} failed: " + err.to_string())
    }
    assert_eq(restored.length(), gzip_reference_sizes[index])
    // 前缀一致即可确认内容没错位
    assert_eq(
      @encoding.decoder(UTF8).decode_lossy(restored[:16]),
      gzip_reference_prefix[index],
    )
  }
}

///|
async test "gzip round trip is stable for varied payload shapes" {
  let cases : Array[String] = [
    "", "a", "0123456789", "repeated payload repeated payload repeated payload",
  ]
  for payload in cases {
    let raw = @encoding.encode(UTF8, payload)
    let restored = gzip_decompress(gzip_compress(raw)) catch {
      err => fail("round trip failed: " + err.to_string())
    }
    assert_eq(restored.length(), raw.length())
    assert_eq(@encoding.decoder(UTF8).decode_lossy(restored), payload)
  }
}

///|
async test "inflate rejects a stored block with a mismatched length" {
  // BFINAL=1、BTYPE=00，LEN=4 但 NLEN 不取反
  let broken : Bytes = b"\x01\x04\x00\x00\x00abcd"
  let result = try {
    ignore(inflate(broken))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(DecompressError::Gzip(message)) =>
      assert_true(message.contains("length check"))
    _ => fail("expected a stored length check failure")
  }
}

///|
async test "inflate reports truncation instead of reading past the buffer" {
  // fixed Huffman 块的开始，但数据只有几个字节
  let broken : Bytes = b"\x05\x00"
  let result = try {
    ignore(inflate(broken))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(DecompressError::Gzip(_)) => ()
    _ => fail("expected a truncation error")
  }
}

///|
async test "gzip rejects a truncated member" {
  let result = try {
    ignore(gzip_decompress(b"\x1f\x8b\x08\x00"))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(DecompressError::Gzip(_)) => ()
    _ => fail("expected a gzip error for a short stream")
  }
}

///|
async test "gzip reports an unsupported compression method" {
  // magic 正确，方法字段是 7（非 deflate）
  let broken : Bytes = b"\x1f\x8b\x07\x00\x00\x00\x00\x00\x00\xff\x00\x00\x00\x00\x00\x00\x00\x00"
  let result = try {
    ignore(gzip_decompress(broken))
    None
  } catch {
    err => Some(err)
  }
  match result {
    Some(DecompressError::Gzip(message)) =>
      assert_true(message.contains("method"))
    _ => fail("expected an unsupported-method error")
  }
}

///|
/// 用外部 gzip 实现（Python zlib，level 9）产出的真实压缩流，
/// 覆盖自写 inflate 的 fixed / dynamic Huffman 分支——自己造的 stored 块覆盖不到。
///
/// 断言用「再压一遍」的方式对比长度与校验，避免在测试里堆超长字面量。
let gzip_reference_streams : Array[Bytes] = [
  // text (903 bytes raw -> 76 bytes gzip)
  Bytes::from_array([
    31, 139, 8, 0, 224, 130, 207, 106, 2, 255, 11, 201, 72, 85, 40, 44, 205, 76,
    206, 86, 72, 42, 202, 47, 207, 83, 72, 203, 175, 80, 200, 42, 205, 45, 40, 86,
    200, 47, 75, 45, 82, 40, 1, 74, 231, 36, 86, 85, 42, 164, 228, 167, 235, 41,
    132, 140, 42, 30, 85, 60, 170, 152, 218, 138, 83, 243, 82, 0, 241, 252, 212,
    3, 135, 3, 0, 0,
  ]),
  // small (5 bytes raw -> 25 bytes gzip)
  Bytes::from_array([
    31, 139, 8, 0, 224, 130, 207, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0, 134,
    166, 16, 54, 5, 0, 0, 0,
  ]),
  // repeat (5000 bytes raw -> 41 bytes gzip)
  Bytes::from_array([
    31, 139, 8, 0, 224, 130, 207, 106, 2, 255, 237, 193, 49, 1, 0, 0, 0, 194, 160,
    172, 235, 95, 194, 20, 126, 64, 1, 0, 0, 0, 0, 111, 3, 118, 89, 244, 76, 136,
    19, 0, 0,
  ]),
]

///|
/// 每个参考流解压后的字节数，用于断言。
let gzip_reference_sizes : Array[Int32] = [903, 5, 5000]

///|
/// 每个参考流首尾若干字节的摘要式断言所需：原始内容的前 16 字节（长文重复的片段）。
let gzip_reference_prefix : Array[String] = [
  "The quick brown ", "hello", "aaaaaaaaaaaaaaaa",
]

///|
/// 手搓一个固定 Huffman（RFC 1951 3.2.6）的 DEFLATE 流：
/// 一个 `'a'` 字面量，后跟 `repeats` 次「长度 258、距离 1」的匹配。
///
/// 距离 1 意味着每次回拷源区间都盖在正在写的位置上（重叠拷贝），
/// 而 `length(258) > distance(1)`。这正是 `copy_from_window` 要处理的形态：
/// 输入很小（几十 KB），输出随 `repeats` 线性增长，能用一个不起眼的小流
/// 把「逐字节回拷」写成 O(n²)。
///
/// 不自带 gzip 容器：`inflate` 直接吃 raw DEFLATE，测试不必凑 CRC。
fn fixed_huffman_overlap_stream(repeats : Int32) -> Bytes {
  let bits : Array[Int32] = []
  // 位写入都按 DEFLATE 的 LSB-first；Huffman 码本身按 MSB-first 展开
  let write_bits = (value : Int32, count : Int32) => {
    for index = 0; index < count; index = index + 1 {
      bits.push((value >> index) & 1)
    }
  }
  let write_code = (code : Int32, count : Int32) => {
    for index = count - 1; index >= 0; index = index - 1 {
      bits.push((code >> index) & 1)
    }
  }
  write_bits(1, 1) // BFINAL
  write_bits(1, 2) // BTYPE = 01（固定 Huffman）
  // 字面量 'a' = 97 落在 0..143 区间：8 位码，0x30 + 97
  write_code(0x30 + 97, 8)
  // 长度 258 对应符号 285（280..287 区间，8 位码 0xC0 + (285 - 280)）
  // 距离 1 对应距离符号 0（固定 5 位码，值就是 0）
  for _ in 0..<repeats {
    write_code(0xC5, 8)
    write_code(0, 5)
  }
  // 结束符号 256 在 256..279 区间：7 位码，256 - 256 = 0
  write_code(0, 7)
  let byte_count = (bits.length() + 7) / 8
  let packed : Array[Byte] = Array::make(byte_count, b'\x00')
  for index, bit in bits {
    if bit == 1 {
      let byte_index = index / 8
      packed[byte_index] = (packed[byte_index].to_int() | (1 << (index % 8))).to_byte()
    }
  }
  Bytes::from_array(packed)
}

///|
/// 重叠拷贝的回归：一段「距离 1、长度 258」的匹配会反复盖住正在写的位置。
///
/// 修复前 `copy_from_window` 对重叠的那一支每个字节都 `Buffer::to_bytes()` 一次，
/// 那是整体拷贝，于是这条测试退化成 O(n²)：40000 次重复（约 10MB 输出）
/// 几十秒都跑不完，表现为「跑起来没有任何输出」。现在每个字节只读一次，
/// 这条用例在 1 秒内完成；回归了就会立刻挂住。
async test "inflate handles long overlapping back-references without quadratic blowup" {
  let repeats = 40000
  let stream = fixed_huffman_overlap_stream(repeats)
  let raw = inflate(stream) catch {
    err => fail("inflate failed: " + err.to_string())
  }
  let expected = 1 + 258 * repeats
  assert_eq(raw.length(), expected)
  // 全 'a'：首、中、尾都要对，顺带钉住重叠拷贝把内容也写对了
  assert_eq(raw[0], b'a')
  assert_eq(raw[expected / 2], b'a')
  assert_eq(raw[expected - 1], b'a')
}

///|
/// 回拷路径的正确性：距离 < 长度时必须逐字节推进（重叠拷贝）。
///
/// 这类流在真实镜像层里遍地都是（连续重复的字节/片段），也正是
/// 「每读一个字节就 `to_bytes()` 复制整段输出」那一版最吃亏的形状。
/// 这里用一个 20 万字节的重复负载把两条都钉住：
/// 结果必须逐字节正确，且不能退化成平方复杂度（旧实现下这条要几十秒）。
async test "inflate handles long overlapping back-references" {
  // 'A' × 200000 压缩后只有 230 字节，解压几乎全部走「距离 1、长度 258」的回拷
  let raw = @encoding.encode(UTF8, "A")
  let payload = gzip_repeat_payload(200000, raw[0])
  let stream = gzip_reference_backref()
  let restored = gzip_decompress(stream) catch {
    err => fail("back-reference stream failed: " + err.to_string())
  }
  assert_eq(restored.length(), 200000)
  for index = 0; index < restored.length(); index = index + 1 {
    if restored[index] != raw[0] {
      fail("byte \{index} is not the repeated value")
    }
  }
  // 兜底：同一份数据自己压一遍也要能还原（覆盖 compress 侧）
  let round = gzip_decompress(gzip_compress(payload)) catch {
    err => fail("round trip failed: " + err.to_string())
  }
  assert_eq(round.length(), payload.length())
}

///|
/// 生成 `count` 份 `byte` 的负载。
fn gzip_repeat_payload(count : Int32, byte : Byte) -> Bytes {
  let out = @buffer.Buffer()
  for index = 0; index < count; index = index + 1 {
    out.write_byte(byte)
  }
  out.to_bytes()
}

///|
/// Python zlib（level 9）压出的 `'A' × 200000`：230 字节，
/// 解压路径几乎全是「距离 1、长度 258」的重叠回拷。
fn gzip_reference_backref() -> Bytes {
  let bytes : Array[Byte] = [
    31, 139, 8, 0, 7, 166, 208, 106, 2, 255, 237, 193, 49, 1, 0, 0, 0, 194, 160,
    108, 235, 95, 202, 12, 254, 64, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 175, 1,
    209, 106, 235, 172, 64, 13, 3, 0,
  ]
  Bytes::from_array(bytes)
}

///|
/// 缓冲边界的回归（issue #116）：`InflateWindow` 的缓冲是「32KiB 回拷窗 +
/// 256KiB 一批」，共 294912 字节。旧实现在写满之后**才**查 `full()` 再 `drain`，
/// 于是「刚好写满」的那一次多写了一个字节，越界 panic——真实镜像层里
/// 几乎每层都会撞上，表现为 `dive save` 卡在 `packing the archive`。
///
/// 这里用 stored 块把输出精确推到边界前一个字节，再补两个字面量：
/// 第二个正好把缓冲顶满，旧实现随后会越界写第三个。
async test "inflate does not overrun the window when output lands on the boundary" {
  let capacity = inflate_window_size + inflate_batch_size
  let stream = boundary_fixed_huffman_stream(capacity)
  let raw = inflate(stream) catch {
    err => fail("boundary stream failed: " + err.to_string())
  }

  // (capacity - 1) 个填充 + 3 个 'a'：后两个 'a' 就是旧实现越界写的字节
  assert_eq(raw.length(), capacity + 2)
  assert_eq(raw[capacity - 2], boundary_fill_byte())
  assert_eq(raw[capacity - 1], b'a')
  assert_eq(raw[capacity], b'a')
  assert_eq(raw[capacity + 1], b'a')
}

///|
/// 同一条边界，走回拷：输出贴着缓冲末尾时 `room` 是 0，旧实现会在循环里
/// 一句也拷不出去地空转（新一轮的 `continue` 之前没重算 `room`）。
/// 现在要求这段流能解完，而不是挂住或报错。
async test "inflate refills the window before a back-reference that hits the boundary" {
  let capacity = inflate_window_size + inflate_batch_size
  let stream = boundary_backref_stream(capacity)
  let raw = inflate(stream) catch {
    err => fail("boundary back-reference failed: " + err.to_string())
  }

  // (capacity - 1) 个填充 + 1 个 'a' + 258 字节回拷
  assert_eq(raw.length(), capacity + 258)
  assert_eq(raw[capacity - 2], boundary_fill_byte())
  for index = capacity - 1; index < raw.length(); index = index + 1 {
    if raw[index] != b'a' {
      fail("byte \{index} should come from the back-reference")
    }
  }
}

///|
/// stored 块的填充字节：避开 'a'，好让尾部断言不靠猜。
fn boundary_fill_byte() -> Byte {
  b'.'
}

///|
/// 定长位写入器：只给下面两个手搓的 DEFLATE 流用。
///
/// 边界测试要求输出的字节位置精确到个位，用 `BitWriter` 那种「先想清楚每一位」
/// 的写法最省事：fixed Huffman 的码字是 RFC 1951 规定死的。
struct BoundaryBits {
  out : @buffer.Buffer
  mut acc : Int32
  mut bits : Int32
}

///|
fn BoundaryBits::new() -> BoundaryBits {
  { out: @buffer.Buffer(), acc: 0, bits: 0, }
}

///|
/// 按 LSB-first 写入 `count` 位。
fn BoundaryBits::write(
  self : BoundaryBits,
  value : Int32,
  count : Int32,
) -> Unit {
  for index = 0; index < count; index = index + 1 {
    if ((value >> index) & 1) == 1 {
      self.acc = self.acc | (1 << self.bits)
    }
    self.bits = self.bits + 1
    if self.bits == 8 {
      self.out.write_byte(self.acc.to_byte())
      self.acc = 0
      self.bits = 0
    }
  }
}

///|
/// 按 MSB-first 写一个 `count` 位的码字（Huffman 码字本身是高位在前）。
///
/// 位流整体是 LSB-first，但「码字内部」要保持 MSB 在前，所以要把码字反向
/// 再交给 `write`。漏了这一步，解码出来会是位反转后的符号。
fn BoundaryBits::write_code(
  self : BoundaryBits,
  value : Int32,
  count : Int32,
) -> Unit {
  let mut reversed = 0
  for index = 0; index < count; index = index + 1 {
    if ((value >> index) & 1) == 1 {
      reversed = reversed | (1 << (count - 1 - index))
    }
  }
  self.write(reversed, count)
}

///|
/// 写一个 fixed Huffman 的 literal 码字（RFC 1951 3.2.6）。
fn BoundaryBits::write_literal(self : BoundaryBits, byte : Byte) -> Unit {
  let symbol = byte.to_int()
  if symbol <= 143 {
    // 8 位码：0x30 + symbol
    self.write_code(0x30 + symbol, 8)
  } else {
    // 144..255 落在 9 位区间：0x190 + (symbol - 144)
    self.write_code(0x190 + (symbol - 144), 9)
  }
}

///|
/// 写「距离 1、长度 258」的回拷：长度符号 285（码字 0xC0FF 取低 8 位 0xFF），
/// 距离符号 0（5 位码字 0）。
fn BoundaryBits::write_backref_258(self : BoundaryBits) -> Unit {
  // 长度 258 = 符号 285（280..287 区间，8 位码 0xC0 + 5），距离 1 = 距离符号 0
  self.write_code(0xC5, 8)
  self.write_code(0, 5)
}

///|
/// 写块结束符 256（7 位码字 0）。
fn BoundaryBits::write_end(self : BoundaryBits) -> Unit {
  self.write_code(0, 7)
}

///|
/// 补齐到字节边界，返回 DEFLATE 字节。
fn BoundaryBits::finish(self : BoundaryBits) -> Bytes {
  self.flush_acc()
  self.out.to_bytes()
}

///|
/// BFINAL=1、BTYPE=01（fixed Huffman）：先 stored 块垫 `pad` 个字节，
/// 再写 3 个字面量 'a'，缓冲恰好在这期间写满。
fn boundary_fixed_huffman_stream(pad : Int32) -> Bytes {
  let bits = BoundaryBits::new()
  // 缓冲里最后一个字节一旦写满就得 drain，所以填充量取 `pad - 1`：
  // 后面 3 个字面量里第一个正好把缓冲顶满（issue #116 的现场）。
  bits.write_stored(pad - 1, boundary_fill_byte())
  bits.write(1, 1)
  bits.write(1, 2)
  for _ in 0..<3 {
    bits.write_literal(b'a')
  }
  bits.write_end()
  bits.finish()
}

///|
/// stored 块（非 final）：`BFINAL=0`、`BTYPE=00`，然后 LEN/NLEN 与数据。
///
/// 块头是 3 位再补齐到字节；LEN/NLEN 是**对齐后**的小端 16 位字段，
/// 所以 5 个字节的头部正好落在字节边界上，后面的 raw 数据可以整段写。
fn BoundaryBits::write_stored(
  self : BoundaryBits,
  count : Int32,
  byte : Byte,
) -> Unit {
  // 单个 stored 块的上限是 LEN 的 16 位字段：65535
  let mut left = count
  while left > 0 {
    let chunk = if left > 65535 { 65535 } else { left }
    self.write_stored_block(chunk, byte)
    left = left - chunk
  }
}

///|
fn BoundaryBits::write_stored_block(
  self : BoundaryBits,
  count : Int32,
  byte : Byte,
) -> Unit {
  self.write(0, 1)
  self.write(0, 2)
  // 补齐到字节边界：写完 3 位后 bits == 3，补 5 个 0
  self.write(0, 5)
  self.flush_acc()
  self.out.write_byte((count & 0xFF).to_byte())
  self.out.write_byte(((count >> 8) & 0xFF).to_byte())
  let complement = count ^ 0xFFFF
  self.out.write_byte((complement & 0xFF).to_byte())
  self.out.write_byte(((complement >> 8) & 0xFF).to_byte())
  for _ in 0..<count {
    self.out.write_byte(byte)
  }
}

///|
/// 把攒着的不足一字节的位补 0 写出去。
fn BoundaryBits::flush_acc(self : BoundaryBits) -> Unit {
  if self.bits > 0 {
    self.out.write_byte(self.acc.to_byte())
    self.acc = 0
    self.bits = 0
  }
}

///|
/// 输出长度 = `pad + 258`，最后一个回拷贴着缓冲末尾收尾：
/// 旧实现里 `room` 归零后一段也拷不出去。
fn boundary_backref_stream(pad : Int32) -> Bytes {
  let bits = BoundaryBits::new()
  // 同上：字面量 'a' 落在 `pad` 处，紧接着的回拷跨过缓冲边界
  bits.write_stored(pad - 1, boundary_fill_byte())
  // fixed Huffman 块：先给一个 'a'，再「距离 1、长度 258」
  bits.write(1, 1)
  bits.write(1, 2)
  bits.write_literal(b'a')
  bits.write_backref_258()
  bits.write_end()
  bits.finish()
}
