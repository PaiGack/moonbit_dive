///|
/// whitebox：位读取器的对齐与位序是最容易出错的地方，单独盯住。
test "BitReader reads bits LSB-first and aligns to the next byte" {
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
test "BitReader keeps byte position when already aligned" {
  let reader = BitReader::new(b"\x01\x10\x00\xef")
  // 读完 8 位后 bits == 0，此时不应再跳过字节
  assert_eq(reader.read_bits(8) catch { _ => fail("read") }, 1)
  reader.align_byte()
  assert_eq(reader.byte, 1)
  assert_eq(reader.read_bits(8) catch { _ => fail("read") }, 0x10)
}

///|
test "inflate decodes a stored block" {
  let raw : Bytes = b"hello stored"
  let compressed = gzip_compress(raw)
  let deflated = compressed[10:compressed.length() - 8]
  let inflated = inflate(deflated) catch {
    err => fail("inflate failed: " + err.to_string())
  }
  assert_eq(inflated.length(), raw.length())
}

///|
test "crc32 matches the reference value for a known input" {
  // CRC32("123456789") = 0xCBF43926，DEFLATE 与 gzip 的通用校验基准
  assert_eq(crc32(b"123456789"), 0xCBF43926U)
  assert_eq(crc32(b""), 0U)
}

///|
test "gzip rejects a stream with a bad magic number" {
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
test "inflate rejects a reserved block type" {
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
test "inflate decodes real streams produced by an external gzip encoder" {
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
test "gzip round trip is stable for varied payload shapes" {
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
test "inflate rejects a stored block with a mismatched length" {
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
test "inflate reports truncation instead of reading past the buffer" {
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
test "gzip rejects a truncated member" {
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
test "gzip reports an unsupported compression method" {
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
test "inflate handles long overlapping back-references without quadratic blowup" {
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
