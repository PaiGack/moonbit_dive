///|
/// 一个 `FILE*`。`x/fs` 里同名的类型是私有的，这里自己开一个口子——
/// 下面的 `fopen` / `fseek` / `fread` / `ftell` / `fclose` 就是 C 的对应物。
///
/// `#external` 不能省：不加它，编译器把这个类型当成自己的堆对象，
/// 会在句柄被回收时按 MoonBit 的对象头去 `free` 一块 `FILE*` ——
/// glibc 那边同一块 `FILE` 内部缓冲会被放两次，于是报
/// `double free or corruption`（issue #120）。加了才是「不透明的外来指针」。
#external
priv type FileHandle

///|
#borrow(path)
extern "C" fn fopen_ffi(path : Bytes) -> FileHandle = "dive_file_open"

///|
#borrow(handle)
extern "C" fn is_null(handle : FileHandle) -> Int32 = "dive_file_is_null"

///|
#borrow(handle)
extern "C" fn fseek_ffi(
  handle : FileHandle,
  offset : Int64,
  whence : Int32,
) -> Int32 = "dive_file_seek"

///|
#borrow(handle)
extern "C" fn ftell_ffi(handle : FileHandle) -> Int64 = "dive_file_tell"

///|
/// 把 `buffer` 里最多 `length` 个字节读进来，返回实际读到的字节数。
/// 两个指针都是 `#borrow`：`fread` 只在调用期间用它们，不保留。
#borrow(handle, buffer)
extern "C" fn fread_ffi(
  handle : FileHandle,
  buffer : Bytes,
  length : Int32,
) -> Int32 = "dive_file_read"

///|
#borrow(handle)
extern "C" fn fclose_ffi(handle : FileHandle) -> Int32 = "dive_file_close"

///|
extern "C" fn get_error_message_ffi() -> Bytes = "dive_last_error"

///|
/// 按偏移读一个文件：现开、现 seek、现读、现关。
///
/// 这里是整个「按需读」的落地端：`moonbitlang/x/fs` 只给「整份读进 `Bytes`」，
/// 而 tar 的随机访问只需要 512 字节的头与一段数据——一份 2 GiB 的归档没有
/// 理由先整个搬进内存（issue #113 的 `Bad address` 就出在整份读上）。
///
/// 底层用 `fopen` / `fseek` / `fread` 三个 C 函数，也就是 `x/fs`
/// 的 `read_file_to_bytes` 内部那几步，只是不必每次从 0 读到尾。
/// `fread` 返回实际读到的字节数，读不满就是文件到这儿结束了；
/// 调用方据此判断「流断了」并给出一条带路径的错。
fn read_file_chunk(
  path : String,
  position : Int64,
  length : Int32,
) -> Result[Bytes, String] noraise {
  if length <= 0 || position < 0L {
    return Ok(Bytes::make(0, b'\x00'))
  }
  let handle = match fopen(path) {
    Ok(handle) => handle
    Err(reason) => return Err(reason)
  }
  let outcome = read_at_handle(handle, position, length)
  fclose(handle)
  outcome
}

///|
/// 打开一个文件（失败抛 `IOError`）。
fn fopen(path : String) -> Result[FileHandle, String] noraise {
  let handle = fopen_ffi(utf8_bytes(path))
  if is_null(handle) == 0 {
    return Ok(handle)
  }
  Err("\{path}: \{last_error()}")
}

///|
/// 在已打开的句柄上读一段。
fn read_at_handle(
  handle : FileHandle,
  position : Int64,
  length : Int32,
) -> Result[Bytes, String] noraise {
  let seeked = fseek_ffi(handle, position, 0)
  if seeked != 0 {
    return Err("cannot seek to \{position}: \{last_error()}")
  }
  let buffer = Bytes::make(length, b'\x00')
  let read = fread_ffi(handle, buffer, length)
  if read < 0 {
    return Err("cannot read \{length} bytes at \{position}: \{last_error()}")
  }
  Ok(buffer[:read].to_owned())
}

///|
/// 关掉句柄。
fn fclose(handle : FileHandle) -> Unit {
  fclose_ffi(handle) |> ignore
}

///|
/// 文件里有多少字节：读到读不动为止。
///
/// `x/fs` 没有 stat，`fseek` 到末尾再 `ftell` 更省事：一次系统调用就有答案。
fn file_length(path : String) -> Result[Int64, String] noraise {
  let handle = match fopen(path) {
    Ok(handle) => handle
    Err(reason) => return Err(reason)
  }
  let size = tell_size(handle)
  fclose(handle)
  size
}

///|
fn tell_size(handle : FileHandle) -> Result[Int64, String] noraise {
  // 终点定位失败（管道、设备文件）就当 0：这类输入本来也不该出现在 tar 里
  let seeked = fseek_ffi(handle, 0L, 2)
  if seeked != 0 {
    return Ok(0L)
  }
  let size = ftell_ffi(handle)
  if size < 0L {
    return Ok(0L)
  }
  Ok(size)
}

///|
/// `UTF8` 编码的 C 字符串（带结尾 NUL）。
fn utf8_bytes(text : String) -> Bytes {
  @encoding.encode(UTF8, text)
}

///|
fn last_error() -> String {
  @encoding.decoder(UTF8).decode_lossy(get_error_message_ffi())
}
