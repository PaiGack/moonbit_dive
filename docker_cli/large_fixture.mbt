///|
/// 大 fixture 归档的流式生成器（测试专用）。
///
/// `build_docker_archive` 造的是「够用就好」的小归档：全在内存里拼，
/// 只证明功能对，证明不了「大镜像不爆内存」。
///
/// 这里换成流式写文件：每条 entry 的 header 与数据块先后落到磁盘，
/// 生成过程本身不驻留整段归档。目标 100MB 量级的 fixture 靠它现造，
/// 仓库里只留生成代码，不塞二进制。
///
/// 归档结构跟 `build_docker_archive` 一致，能被 `parse_docker_archive`
/// 与 P2 的 `apply_layers_with_diffs` 直接吃下：
/// 一个 `<id>/layer.tar` 层、一个 config、一个 manifest.json。
///
/// 只面向 POSIX：内存测量读 `/proc/self/status`。
#cfg(not(platform="windows"))
const TAR_BLOCK : Int32 = 512

///|
/// 生成一个大 docker-archive 到 `path`，内容约 `target_bytes`。
///
/// 只有一个层，层里的文件用重复字节填到目标体积。
/// 返回实际写入的字节数（tar 按块对齐，会比 target 略大）。
///
/// 内存里只有 64KB 的填充缓冲：无论目标多大，峰值占用不随体积增长。
#cfg(not(platform="windows"))
pub async fn write_large_archive(
  path : String,
  target_bytes : Int32,
  layer_id~ : String = "deadbeef",
) -> Int32 raise DockerCliError {
  let handle = @fs.open(
    path,
    mode=@fs.Mode::WriteOnly,
    create_mode=@fs.CreateMode::CreateOrTruncate,
  ) catch {
    err => raise Backend(path, -1, "cannot open archive for writing: \{err}")
  }
  defer handle.close()
  let mut written = 0
  // 层数据：填到「目标减去 header / config / manifest 的余量」
  let overhead = estimate_overhead(layer_id)
  let payload = if target_bytes > overhead {
    target_bytes - overhead
  } else {
    0
  }
  let layer_name = "\{layer_id}/layer.tar"
  written = written + write_header(handle, layer_name, payload, b'0', 0o644)
  written = written + write_filler(handle, payload)
  written = written + write_padding(handle, payload)
  let config_name = "\{layer_id}.json"
  let config = @utf8.encode("{\"architecture\":\"amd64\",\"os\":\"linux\"}")
  written = written +
    write_header(handle, config_name, config.length(), b'0', 0o644)
  written = written + write_raw(handle, config)
  written = written + write_padding(handle, config.length())
  let manifest = @utf8.encode(
    "[{\"Config\":\"\{config_name}\",\"RepoTags\":[\"example:latest\"]," +
    "\"Layers\":[\"\{layer_name}\"]}]",
  )
  written = written +
    write_header(handle, "manifest.json", manifest.length(), b'0', 0o644)
  written = written + write_raw(handle, manifest)
  written = written + write_padding(handle, manifest.length())
  // tar 结束标记：两个全零块
  let zeros = FixedArray::make(TAR_BLOCK * 2, b'\x00').unsafe_reinterpret_as_bytes()
  written = written + write_raw(handle, zeros)
  written
}

///|
/// 估算 header / config / manifest / 结束块占的字节，
/// 让层的 payload 正好把总量顶到 `target_bytes`。
#cfg(not(platform="windows"))
fn estimate_overhead(layer_id : String) -> Int32 {
  let layer_header = TAR_BLOCK
  let config_header = TAR_BLOCK
  let config_body = 64
  let manifest_header = TAR_BLOCK
  let manifest_body = 256
  let end_blocks = TAR_BLOCK * 2
  ignore(layer_id)
  layer_header +
  config_header +
  config_body +
  config_header +
  manifest_header +
  manifest_body +
  end_blocks
}

///|
/// 写一条 tar header。只支持固定短路径（测试 fixture 用不到长路径拆分）。
#cfg(not(platform="windows"))
async fn write_header(
  handle : @fs.File,
  name : String,
  size : Int32,
  entry_type : Byte,
  mode : Int32,
) -> Int32 raise DockerCliError {
  let header = FixedArray::make(TAR_BLOCK, b'\x00')
  let name_bytes = @utf8.encode(name)
  if name_bytes.length() >= 100 {
    raise Backend(name, -1, "fixture path too long for a plain ustar header")
  }
  copy_into(header, 0, name_bytes)
  copy_into(header, 100, @utf8.encode(octal(mode, 7) + "\u{0}"))
  copy_into(header, 108, @utf8.encode(octal(0, 7) + "\u{0}"))
  copy_into(header, 116, @utf8.encode(octal(0, 7) + "\u{0}"))
  copy_into(header, 124, @utf8.encode(octal(size, 11) + "\u{0}"))
  copy_into(header, 136, @utf8.encode(octal(0, 11) + "\u{0}"))
  copy_into(header, 148, @utf8.encode("        "))
  header[156] = entry_type
  copy_into(header, 257, @utf8.encode("ustar\u{0}"))
  copy_into(header, 263, @utf8.encode("00"))
  let checksum = header.fold(init=0, (acc, byte) => acc + byte.to_int())
  copy_into(header, 148, @utf8.encode(octal(checksum, 6) + "\u{0} "))
  write_raw(handle, header.unsafe_reinterpret_as_bytes())
}

///|
/// 写 `count` 个填充字节（固定 64KB 缓冲循环写，不按 count 分配）。
#cfg(not(platform="windows"))
async fn write_filler(
  handle : @fs.File,
  count : Int32,
) -> Int32 raise DockerCliError {
  let chunk = FixedArray::make(64 * 1024, b'\x5a').unsafe_reinterpret_as_bytes()
  let mut remaining = count
  let mut written = 0
  while remaining > 0 {
    let take = @cmp.minimum(chunk.length(), remaining)
    written = written + write_raw(handle, chunk[:take].to_owned())
    remaining = remaining - take
  }
  written
}

///|
/// 补零到 512 字节边界。
#cfg(not(platform="windows"))
async fn write_padding(
  handle : @fs.File,
  size : Int32,
) -> Int32 raise DockerCliError {
  let padding = (TAR_BLOCK - size % TAR_BLOCK) % TAR_BLOCK
  if padding == 0 {
    return 0
  }
  let zeros = FixedArray::make(padding, b'\x00').unsafe_reinterpret_as_bytes()
  write_raw(handle, zeros)
}

///|
/// 往文件写一段字节，返回写出的长度。
#cfg(not(platform="windows"))
async fn write_raw(
  handle : @fs.File,
  bytes : Bytes,
) -> Int32 raise DockerCliError {
  handle.write(bytes) catch {
    err => raise Backend("archive", -1, "write failed: \{err}")
  }
  bytes.length()
}

///|
/// 把字节复制进定长字段，超出部分丢弃。
#cfg(not(platform="windows"))
fn copy_into(field : FixedArray[Byte], offset : Int32, bytes : Bytes) -> Unit {
  for index, byte in bytes {
    if offset + index >= field.length() {
      break
    }
    field[offset + index] = byte
  }
}

///|
/// 八进制字段，跟 tar 的惯例一致（不含前导 `0o`）。
#cfg(not(platform="windows"))
fn octal(value : Int32, digits : Int32) -> String {
  let mut text = ""
  let mut remaining = value
  let mut count = 0
  while count < digits {
    let digit = remaining % 8
    text = Int32::unsafe_to_char('0'.to_int() + digit).to_string() + text
    remaining = remaining / 8
    count = count + 1
  }
  text
}
