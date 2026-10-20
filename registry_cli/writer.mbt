///|
/// 一个「转发给文件 + 数着自己写了多少字节」的写入器。
///
/// docker-archive 的 tar 头里要写死每条 entry 的长度，而层的长度只有解压完
/// 才知道。这里顺手把写出的字节数记下来，调用方据此核对「头里写的」与
/// 「实际写的」是否一致——不一致的 tar 能读，但内容会错位，比报错难查。
///
/// 另外它还负责 `close`：一半的 tar 留在磁盘上，下次 `docker load` 会报一个
/// 完全无关的截断错误，所以出错路径也要能把 fd 收干净。
pub struct CountingWriter {
  file : @fs.File
  mut total : Int64
}

///|
fn CountingWriter::new(file : @fs.File) -> CountingWriter {
  { file, total: 0L, }
}

///|
/// 已写出的字节数。
fn CountingWriter::written(self : CountingWriter) -> Int64 {
  self.total
}

///|
fn CountingWriter::close(self : CountingWriter) -> Unit {
  self.file.close()
}

///|
pub impl @io.Writer for CountingWriter with fn write_once(
  self : CountingWriter,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let chunk = buf[offset:offset + len]
  self.file.write(chunk)
  self.total = self.total + chunk.length().to_int64()
  len
}

///|
pub extend CountingWriter with @io.Writer::{write_once, write, write_reader}

///|
/// 一个「转发给下游、顺手记下写了多少字节」的写入器。
///
/// 打包 docker-archive 时每层都要先解压一遍拿到 `<diff-id>`（未压缩 tar 的
/// sha256）与长度，而这一遍的字节并不需要留在内存里——留在内存里正是
/// issue #97 的现场。这里把它们就地扔掉，只留 32 字节摘要与一个长度。
pub struct HashingWriter {
  hasher : @crypto.SHA256
  mut total : Int64
}

///|
fn HashingWriter::new() -> HashingWriter {
  { hasher: @crypto.SHA256::new(), total: 0L, }
}

///|
/// 收尾：(解压后的字节数, 小写 hex 摘要)。
fn HashingWriter::result(self : HashingWriter) -> (Int32, String) {
  let digest = self.hasher.finalize()
  (self.total.to_int(), @crypto.bytes_to_hex_string(digest))
}

///|
pub impl @io.Writer for HashingWriter with fn write_once(
  self : HashingWriter,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let chunk = buf[offset:offset + len]
  self.hasher.update(chunk)
  self.total = self.total + chunk.length().to_int64()
  len
}

///|
pub extend HashingWriter with @io.Writer::{write_once, write, write_reader}

///|
/// 一个「攒成一块字节」的写入器：给测试和小产物当落地端。
///
/// 生产链路不用它——`docker save` 一个 700MB 的镜像时，
/// 「先在内存里攒成一块」正是 issue #97 的那条路。
pub struct BytesBuffer {
  buffer : @buffer.Buffer
}

///|
pub fn BytesBuffer::new() -> BytesBuffer {
  { buffer: @buffer.Buffer(size_hint=8192), }
}

///|
pub fn BytesBuffer::to_bytes(self : BytesBuffer) -> Bytes {
  self.buffer.to_bytes()
}

///|
pub impl @io.Writer for BytesBuffer with fn write_once(
  self : BytesBuffer,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  self.buffer.write_bytes(buf[offset:offset + len])
  len
}

///|
pub extend BytesBuffer with @io.Writer::{write_once, write, write_reader}
