/*
 * 按偏移读文件的最小 C 入口。
 *
 * `moonbitlang/x/fs` 只给「整份读进 Bytes」（`read_file_to_bytes`），
 * 而 tar 的随机访问只想要「512 字节头」与「一段数据」。一份 2 GiB 的
 * docker-archive 先整个读进内存，正是 issue #113 里 `Bad address` 的现场：
 * 长度越过 Int32 边界，任何一处按 Int32 截断都会变成「读到一个非法地址」。
 *
 * 所以这里补三个最普通的 C 函数：fopen / fseek / fread / ftell / fclose。
 * 返回值约定：
 *   - 句柄走返回值，失败时是 NULL，错误信息用 `dive_last_error` 取
 *   - 定位失败返回非 0，读到的字节数走返回值（>= 0）
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <moonbit.h>

/*|
打开一个只读文件。`path` 是 UTF-8 的 C 字符串。
*/
MOONBIT_FFI_EXPORT
FILE *dive_file_open(const char *path) {
  return fopen(path, "rb");
}

/*|
句柄是否为 NULL（0 表示拿不到）。
*/
MOONBIT_FFI_EXPORT
int32_t dive_file_is_null(FILE *handle) {
  return handle == NULL ? 1 : 0;
}

/*|
定位。`whence` 与 C 一致：0 = 起点，2 = 末尾。成功返回 0。
*/
MOONBIT_FFI_EXPORT
int32_t dive_file_seek(FILE *handle, int64_t offset, int32_t whence) {
  return fseek(handle, (long)offset, whence) == 0 ? 0 : -1;
}

/*|
当前位置；失败返回 -1。
*/
MOONBIT_FFI_EXPORT
int64_t dive_file_tell(FILE *handle) {
  long position = ftell(handle);
  return position < 0 ? -1 : (int64_t)position;
}

/*|
读一段：把 `buffer` 里最多 `length` 个字节读进来，返回实际读到的字节数。
读到的字节数小于请求量就是文件到这儿结束了。
*/
MOONBIT_FFI_EXPORT
int32_t dive_file_read(FILE *handle, moonbit_bytes_t buffer, int32_t length) {
  size_t read = fread(buffer, 1, (size_t)length, handle);
  return (int32_t)read;
}

/*|
关掉句柄；失败返回 -1。
*/
MOONBIT_FFI_EXPORT
int32_t dive_file_close(FILE *handle) {
  return fclose(handle) == 0 ? 0 : -1;
}

/*|
上一次失败的原因（`strerror(errno)`）。
*/
MOONBIT_FFI_EXPORT
moonbit_bytes_t dive_last_error(void) {
  const char *message = strerror(errno);
  size_t length = strlen(message);
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)length, 0);
  memcpy(bytes, message, length);
  return bytes;
}
