///|
/// tar 解析错误：格式不合法、字段越界或数据被截断。
pub(all) suberror TarError {
  Truncated(String)
  BadHeader(String)
  InvalidNumber(String, String)
  /// 流已读完（零块或尾部填充）：给 `TarReader::next` 当循环出口用，
  /// 不是错误，是「没有下一条」的信号
  NotFound
} derive(Eq, Debug)

///|
pub extend TarError with Eq::{equal, not_equal}

///|
pub extend TarError with @debug.Debug::{to_repr}

///|
pub impl Show for TarError with fn to_string(self) {
  match self {
    Truncated(what) => "truncated tar stream: \{what}"
    BadHeader(reason) => "invalid tar header: \{reason}"
    InvalidNumber(field, raw) =>
      "invalid \{field} field in tar header: \"\{raw}\""
    NotFound => "end of tar stream"
  }
}

///|
pub extend TarError with Show::{to_string, output}

///|
/// 解压错误：gzip / zstd 流损坏或使用了不支持的压缩算法。
pub(all) suberror DecompressError {
  Gzip(String)
  Zstd(String)
  Unsupported(String)
} derive(Eq, Debug)

///|
pub extend DecompressError with Eq::{equal, not_equal}

///|
pub extend DecompressError with @debug.Debug::{to_repr}

///|
pub impl Show for DecompressError with fn to_string(self) {
  match self {
    Gzip(reason) => "invalid gzip stream: \{reason}"
    Zstd(reason) => "invalid zstd stream: \{reason}"
    Unsupported(algorithm) => "unsupported layer compression: \{algorithm}"
  }
}

///|
pub extend DecompressError with Show::{to_string, output}

///|
/// 把一层 tar 应用到文件树时的错误。
///
/// digest 校验失败单独成一类：它意味着层内容与 manifest 描述不一致。
pub(all) suberror LayerError {
  Tar(TarError)
  Decompress(DecompressError)
  DigestMismatch(String, String)
  PathEscape(String)
} derive(Eq, Debug)

///|
pub extend LayerError with Eq::{equal, not_equal}

///|
pub extend LayerError with @debug.Debug::{to_repr}

///|
pub impl Show for LayerError with fn to_string(self) {
  match self {
    Tar(err) => err.to_string()
    Decompress(err) => err.to_string()
    DigestMismatch(expected, actual) =>
      "layer digest mismatch: expected \{expected}, got \{actual}"
    PathEscape(path) => "tar entry path escapes the root: \"\{path}\""
  }
}

///|
pub extend LayerError with Show::{to_string, output}

///|
/// 从 tar/路径相关的错误里取出人类可读的描述。
pub fn LayerError::message(self : LayerError) -> String {
  self.to_string()
}
