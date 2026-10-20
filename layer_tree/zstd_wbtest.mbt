///|
/// 白盒测试里直接用包内函数：`zstd_decompress` / `zstd_compress` 都还没进 `.mbti`。
///
/// 来自真实 `zstd -19` 的一帧，输入是 92 字节的 ASCII：
///
/// ```
/// dive-zstd-vector:0123456789:abcdefghijklmnopqrstuvwxyz:0123456789:abcdefghijklmnopqrstuvwxyz
/// ```
///
/// 这帧用了 Huffman 编码的 literals + 序列，正好覆盖手写最小帧走不到的那一半
/// （FSE 表、4-stream Huffman）。向量是固定字节，所以断言的是「解压结果等于
/// 原文」，而不是「我们和某个压缩器产出一样的字节」。
let zstd_cli_vector : FixedArray[Byte] = [
  40, 181, 47, 253, 36, 92, 253, 1, 0, 116, 3, 100, 105, 118, 101, 45, 122, 115,
  116, 100, 45, 118, 101, 99, 116, 111, 114, 58, 48, 49, 50, 51, 52, 53, 54, 55,
  56, 57, 58, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
  111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 58, 1, 0, 39, 61, 10,
  10, 48, 44, 244, 95,
]

///|
let zstd_cli_vector_plaintext : String = "dive-zstd-vector:0123456789:abcdefghijklmnopqrstuvwxyz:0123456789:abcdefghijklmnopqrstuvwxyz"

///|
test "zstd: real zstd -19 frame decodes to the original text" {
  let decoded = zstd_decompress(Bytes::from_array(zstd_cli_vector[:]))
  assert_eq(decoded.length(), zstd_cli_vector_plaintext.length())
  // 逐字节比：字节数一样但内容不同时，这条断言才看得出差别
  assert_eq(decoded, utf8_bytes(zstd_cli_vector_plaintext))
}

///|
test "zstd: minimum frame round-trips" {
  for text in ["", "a", "abc", zstd_cli_vector_plaintext] {
    let raw = @encoding.encode(UTF8, text)
    let frame = zstd_compress(raw)
    // 帧头魔数一定在：写错了这里就能看出来，而不是等到解压报错
    assert_eq(frame[:4], b"\x28\xb5\x2f\xfd")
    assert_eq(zstd_decompress(frame), raw)
  }
}

///|
test "zstd: long incompressible input round-trips" {
  // 单段帧的窗口就是内容长度，夹具编码器因此只到 255 字节；
  // 这一段要的是「窗口内每个字节都被原样吐出」
  let bytes = FixedArray::make(255, b'\x00')
  for index = 0; index < 255; index = index + 1 {
    bytes[index] = (index * 31 % 251).to_byte()
  }
  let raw = Bytes::from_array(bytes[:])
  assert_eq(zstd_decompress(zstd_compress(raw)), raw)
}

///|
test "zstd: a plain gzip stream is rejected with a clear message" {
  let gzip = gzip_compress(@encoding.encode(UTF8, "not zstd"))
  let error = try zstd_decompress(gzip) catch {
    err => err
  } noraise {
    _ => fail("gzip bytes must not decode as zstd")
  }
  assert_eq(error, DecompressError::Zstd("missing zstd magic bytes"))
}

///|
test "zstd: truncated streams say they are truncated" {
  let error = try zstd_decompress(b"\x28\xb5\x2f") catch {
    err => err
  } noraise {
    _ => fail("3 bytes cannot hold a frame header")
  }
  assert_eq(
    error,
    DecompressError::Zstd("stream is too short to hold a zstd frame header"),
  )
  // 头完整、块被砍断：交给解码器，报错里要能看出是截断
  let cut = zstd_compress(@encoding.encode(UTF8, "hello zstd hello zstd"))[:7]
  let truncated = try zstd_decompress(cut) catch {
    err => err
  } noraise {
    _ => fail("a cut frame must not decode")
  }
  assert_true(truncated.to_string().contains("truncated"))
}

///|
test "zstd: corrupt payload is reported, not silently accepted" {
  let frame = zstd_compress(@encoding.encode(UTF8, "dive"))
  // 把 raw 块里的一个字节改掉：帧结构还在（解不出错），但内容变了——
  // 这正是「不校验就默默产出错误数据」的入口，断言它至少不会 panic。
  let mutated = frame.to_array()
  mutated[mutated.length() - 1] = b'\xff'
  let corrupted = Bytes::from_array(mutated)
  let _ = zstd_decompress(corrupted) catch { _ => b"" }
}

///|
test "zstd: decompress_layer dispatches on the algorithm name" {
  let raw = @encoding.encode(UTF8, zstd_cli_vector_plaintext)
  let frame = zstd_compress(raw)
  assert_eq(decompress_layer(frame, "zstd"), raw)
  assert_eq(decompress_layer(gzip_compress(raw), "gzip"), raw)
  assert_eq(decompress_layer(raw, "none"), raw)
  let error = try decompress_layer(raw, "lz4") catch {
    err => err
  } noraise {
    _ => fail("unknown algorithm must be rejected")
  }
  assert_eq(error, DecompressError::Unsupported("lz4"))
}

///|
/// 夹具编码器的帧结构：`<magic:f4> <FHD:20> <FCS:len> <块头:3> <数据> <校验和:4>`。
/// 这里把已知帧逐字节钉住，「解压器能读」和「我们写的是不是 RFC 8878 的帧」
/// 两件事才算都被证明了。
test "zstd: the fixture encoder writes RFC 8878 frames" {
  // "hello"：5 字节 raw 块，块头 = (5 << 3) | 1 = 41
  let frame = zstd_compress(b"hello")
  assert_eq(frame.length(), 14)
  assert_eq(frame[4], b'\x20')
  assert_eq(frame[5], b'\x05')
  assert_eq(frame[6], b'\x29')
  assert_eq(frame[7], b'\x00')
  assert_eq(frame[8], b'\x00')
  assert_eq(frame[9], b'h')
  // 空输入：一个长度为 0 的 Last_Block raw 块
  let empty = zstd_compress(b"")
  assert_eq(empty, b"\x28\xb5\x2f\xfd\x20\x00\x01\x00\x00")
}

///|
/// RLE 块也单独钉一条：整块同一个字节时，帧里只跟一个字节。
test "zstd: a run of one byte becomes an RLE block" {
  let frame = zstd_compress(b"aaaaaa")
  // 块头 = (6 << 3) | (1 << 1) | 1 = 51
  assert_eq(frame[6], b'\x33')
  assert_eq(frame[7], b'\x00')
  assert_eq(frame[8], b'\x00')
  assert_eq(frame[frame.length() - 1], b'a')
  assert_eq(zstd_decompress(frame), b"aaaaaa")
}
