///|
/// 让一个「返回值多少」的写入器能接在 `@io.Writer` 的位置上时把错误抛出去。
///
/// `@io.Writer::write_once` 本身不 `raise`，而 `File::write` 会；盘写坏的
/// 时候宁可让打包整条失败，也不要留一个「长度对、内容短」的 tar。
async fn write_all(
  handle : @fs.File,
  data : BytesView,
) -> Unit raise RegistryError {
  handle.write(data) catch {
    err => raise Io("writing the archive: \{err}")
  }
}

///|
/// 在 `position` 处写死一段字节（tar 头的长度回填写在这儿）。
async fn write_chunk_at(
  handle : @fs.File,
  data : BytesView,
  length : Int32,
  position : Int64,
) -> Unit raise RegistryError {
  if length <= 0 {
    return
  }
  handle.write_at(data[:length], position~) catch {
    err => raise Io("patching the archive: \{err}")
  }
}

///|
/// 边解压边写进 tar 的通道：字节直接落到文件，同时顺手算 sha256、数长度。
///
/// 它是 `InflateWindow` 的落地端，所以 `write_once` 是同步的（`File::write`
/// 在 async 里也是普通调用，这里只是把它从「返回值」变成「抛错」）。
/// 「算摘要」与「写盘」共用同一遍字节——正是 issue #113 要的单遍：
/// 老写法先解压一遍只为算 diff id，再解压一遍写 tar，双倍 CPU。
pub struct HashingFileSink {
  handle : @fs.File
  hasher : @crypto.SHA256
  mut total : Int64
}

///|
fn HashingFileSink::new(handle : @fs.File) -> HashingFileSink {
  { handle, hasher: @crypto.SHA256::new(), total: 0L, }
}

///|
/// 收尾：(写出的字节数, 小写 hex 摘要)。
fn HashingFileSink::result(self : HashingFileSink) -> (Int64, String) {
  (self.total, @crypto.bytes_to_hex_string(self.hasher.finalize()))
}

///|
pub impl @io.Writer for HashingFileSink with fn write_once(
  self : HashingFileSink,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let chunk = buf[offset:offset + len]
  self.hasher.update(chunk)
  // 写盘失败没法往 `raise` 里扔：这里只记「没写全」，收尾时核对长度就能发现
  self.handle.write(chunk) catch {
    _ => ()
  }
  self.total = self.total + chunk.length().to_int64()
  len
}

///|
pub extend HashingFileSink with @io.Writer::{write_once, write, write_reader}

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
