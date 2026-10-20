///|
/// zstd 解压：`application/vnd.oci.image.layer.v1.tar+zstd` 这类层的解码入口。
///
/// 解码器本身来自 `gaato/zstd`（纯 MoonBit、流式、只做解码）。选择它的理由是
/// 接口形状：`decompress` 直接吃 `BytesView`，与 `gzip_decompress` 的签名一致，
/// 上面几层（`decompress_layer` / `decompress_layers` / `apply_layer_with_media_type`）
/// 因此不需要为 zstd 单独开一条路径。
///
/// 错误统一归到 `DecompressError::Zstd`：`gaato/zstd` 的错误类型没有 `Show`，
/// 这里按 `ZstdErrorKind` 翻成稳定、可断言的文案，避免把上游的 `Debug` 形态
/// 漏进用户的错误信息里。
pub fn zstd_decompress(data : BytesView) -> Bytes raise DecompressError {
  // 帧头魔数 `0x FD 2F B5 28`（小端）或可跳过帧 `0x 2A 4D 18 50..5F`。
  // 先自己判一遍：空数据 / 被截断到 3 字节以内的输入交给解码器只会报
  // 一个笼统的 `Truncated`，而这里能说清是「根本不是 zstd」还是「头不完整」。
  if data.length() < 4 {
    raise Zstd("stream is too short to hold a zstd frame header")
  }
  if !is_zstd_frame_magic(data) {
    raise Zstd("missing zstd magic bytes")
  }
  @zstd.decompress(data, max_output=zstd_max_output) catch {
    err => raise Zstd(zstd_error_message(err))
  }
}

///|
/// 单层解压后的字节数上限。
///
/// `gaato/zstd` 每帧最多展开到 `2^max_window_bits`（默认 128 MiB）；镜像层里
/// 存在空窗口（整帧就是一个 RLE 块）的写法，那种帧不受窗口约束，所以再给一个
/// 硬上限，避免一份畸形层把内存吃光。1 GiB 是「离谱但还没越界」的量级。
let zstd_max_output : Int32 = 1024 * 1024 * 1024

///|
let zstd_frame_magic : FixedArray[Byte] = [b'\x28', b'\xb5', b'\x2f', b'\xfd']

///|
/// 判断前 4 字节是不是 zstd 帧魔数。
///
/// 可跳过帧（`skippable frame`，`0x184D2A50..5F`）本身不含数据，`gaato/zstd`
/// 会照 RFC 8878 跳过它；镜像层里不会出现，但认出来能给出更准的错误。
fn is_zstd_frame_magic(data : BytesView) -> Bool {
  let mut frame = true
  for index = 0; index < 4; index = index + 1 {
    if data[index] != zstd_frame_magic[index] {
      frame = false
    }
  }
  if frame {
    return true
  }
  // 小端读出来落在 0x184D2A50..0x184D2A5F 就是可跳过帧
  let magic = data[0].to_int() |
    (data[1].to_int() << 8) |
    (data[2].to_int() << 16) |
    (data[3].to_int() << 24)
  magic >= 0x184D2A50 && magic <= 0x184D2A5F
}

///|
/// 把解码器的错误翻成一句能贴进报告的话。
fn zstd_error_message(err : @zstd.ZstdError) -> String {
  let @zstd.ZstdError(kind, detail) = err
  match kind {
    @zstd.Truncated => "truncated zstd frame: \{detail}"
    @zstd.Corrupt => "corrupt zstd frame: \{detail}"
    @zstd.ChecksumMismatch => "zstd checksum mismatch: \{detail}"
    @zstd.WindowTooLarge => "zstd frame needs an oversized window: \{detail}"
    @zstd.DictionaryUnsupported =>
      "zstd frame needs a dictionary (OCI layers never carry one): \{detail}"
    @zstd.OutputLimitExceeded =>
      "zstd frame expands past \{zstd_max_output} bytes: \{detail}"
    // 解码库以后可能加新错误码，未知的照样把原文透给用户
    @zstd.ZstdErrorKind::.. => detail
  }
}

///|
/// zstd 压缩：**只为测试与夹具**，一个最小编码器，不做熵编码。
///
/// 生产链路只解压（层是外部产物）。但「解压器对不对」得拿真压缩字节才验得了，
/// 而 `gaato/zstd` 只做解码、不带编码器；为造夹具再引一个压缩库不划算。
/// 所以这里手写：帧头 + 若干 RLE / raw 块 + 帧尾校验和。解压它要依次走帧头解析、
/// 块循环、RLE 展开、raw 拷贝、XXH64 校验——唯独绕开 FSE/Huffman，
/// 那部分交给真实 `zstd` 产出的字节（见 `zstd_wbtest.mbt` 里的 CLI 向量）。
///
/// 帧格式按 RFC 8878 3.1.1 摆：
/// - FHD = `0b0010_0000`：单段帧（bit5，省掉 window descriptor，
///   窗口即内容长度）、FCS 用 1 字节（bit7..6 = `0b00` 且单段帧）、
///   不写内容校验和（bit2 = 0，`gaato/zstd` 这条路径不核，夹具也不假装写）。
/// - 单段帧的窗口就是内容长度，而解压器要求「窗口 ≥ 块大小」，
///   所以输入上限是 255 字节——刚好够造一两个 tar entry 的夹具。
///
/// 需要更长输入时用真实 `zstd` 产出的向量（见 `zstd_wbtest.mbt`）。
pub fn zstd_compress(data : BytesView) -> Bytes {
  let length = data.length()
  if length > 0xff {
    abort(
      "zstd_compress is a fixture helper: single-segment frames cap out at 255 bytes",
    )
  }
  let output = Buffer()
  output.write_bytes(b"\x28\xb5\x2f\xfd")
  output.write_byte(b'\x20')
  output.write_byte(length.to_byte())
  let mut offset = 0
  while offset < length {
    let block = if length - offset > zstd_max_block {
      zstd_max_block
    } else {
      length - offset
    }
    let last = offset + block >= length
    // 整块同一个字节发 RLE，否则原样发 raw：解压侧两条分支都被走到
    let mut uniform = true
    for index = offset + 1; index < offset + block; index = index + 1 {
      if data[index] != data[offset] {
        uniform = false
      }
    }
    if uniform {
      write_zstd_block_header(output, block, zstd_block_rle, last)
      output.write_byte(data[offset])
    } else {
      write_zstd_block_header(output, block, zstd_block_raw, last)
      output.write_bytes(data[offset:offset + block])
    }
    offset = offset + block
  }
  if length == 0 {
    // 空帧：一个 Last_Block 的 raw 块，Regenerated_Size = 0
    write_zstd_block_header(output, 0, zstd_block_raw, true)
  }
  output.to_bytes()
}

///|
/// 单块上限：RFC 8878 的 `Block_Maximum_Size`。255 字节的输入够不到，
/// 留着是为了以后放宽 FCS 宽度时这里不用改。
let zstd_max_block : Int32 = 128 * 1024

///|
let zstd_block_raw : Int32 = 0

///|
let zstd_block_rle : Int32 = 1

///|
/// 块头是 3 字节小端：bit0 是 Last_Block，bit1..2 是 Block_Type，
/// 高位是 Block_Size（raw / RLE 块里都等于 Regenerated_Size）。
fn write_zstd_block_header(
  output : @buffer.Buffer,
  size : Int32,
  block_type : Int32,
  last : Bool,
) -> Unit {
  let header = (if last { 1 } else { 0 }) | (block_type << 1) | (size << 3)
  output.write_byte((header & 0xff).to_byte())
  output.write_byte(((header >> 8) & 0xff).to_byte())
  output.write_byte(((header >> 16) & 0xff).to_byte())
}
