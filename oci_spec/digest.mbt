///|
/// digest 解析/校验错误。
///
/// 与 image-spec 的 `ErrDigestUnsupported` / `ErrDigestInvalidFormat` 对应，
/// 拆成细分构造子便于调用方给出精确提示。
pub(all) suberror DigestError {
  EmptyDigest
  MissingSeparator(String)
  MissingAlgorithm(String)
  EmptyEncoded(String)
  UnsupportedAlgorithm(String, Array[String])
  InvalidLength(String, Int32, Int32)
  InvalidHexChar(String, Char, Int32)
  /// 格式合法但含大写 hex（OCI digest 必须小写）
  NotLowercase(String)
} derive(Eq, Debug)

///|
pub extend DigestError with Eq::{equal, not_equal}

///|
pub extend DigestError with @debug.Debug::{to_repr}

///|
/// 把错误渲染成人能读的句子。
pub impl Show for DigestError with fn to_string(self) {
  match self {
    EmptyDigest => "digest is empty"
    MissingSeparator(raw) =>
      "digest \"\{raw}\" has no \"algorithm:encoded\" separator"
    MissingAlgorithm(raw) => "digest \"\{raw}\" is missing the algorithm part"
    EmptyEncoded(raw) => "digest \"\{raw}\" is missing the encoded part"
    UnsupportedAlgorithm(algorithm, supported) =>
      "unsupported digest algorithm \"\{algorithm}\", supported: \{supported.join(", ")}"
    InvalidLength(algorithm, expected, actual) =>
      "\{algorithm} digest must be \{expected} hex characters, got \{actual}"
    InvalidHexChar(algorithm, ch, index) =>
      "invalid hex character '\{ch}' at index \{index} of \{algorithm} digest"
    NotLowercase(raw) => "digest \"\{raw}\" must use lowercase hex characters"
  }
}

///|
pub extend DigestError with Show::{to_string, output}

///|
/// 一个已校验的 digest：`algorithm:encoded`。
///
/// 该类型保证 encoded 全为小写 hex 且长度与算法匹配（sha256 = 64, sha512 = 128）。
/// 通过 `Digest::parse` 构造，不会持有非法状态。
pub(all) struct Digest {
  /// 小写算法名，如 `sha256`
  algorithm : String
  /// 小写 hex 编码
  encoded : String
} derive(Eq, Debug)

///|
pub extend Digest with Eq::{equal, not_equal}

///|
pub extend Digest with @debug.Debug::{to_repr}

///|
pub impl Show for Digest with fn to_string(self) {
  "\{self.algorithm}:\{self.encoded}"
}

///|
pub extend Digest with Show::{to_string, output}

///|
pub impl ToJson for Digest with fn to_json(self) {
  Json::string(self.to_string())
}

///|
pub extend Digest with ToJson::{to_json}

///|
pub impl FromJson for Digest with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let raw = @json.from_json(json) catch {
    error => raise decode_error(loc, error.to_string())
  }
  match Digest::parse(raw) {
    Ok(digest) => digest
    Err(err) => raise decode_error(loc, err.to_string())
  }
}

///|
pub extend Digest with FromJson::{from_json}

///|
/// 已知算法 -> hex 编码长度。
fn digest_hex_length(algorithm : String) -> Int32? {
  match algorithm {
    "sha256" => Some(64)
    "sha512" => Some(128)
    _ => None
  }
}

///|
pub let supported_digest_algorithms : Array[String] = ["sha256", "sha512"]

///|
/// 解析并校验 `algorithm:encoded` 形式的 digest。
///
/// 校验项：非空、含冒号、算法受支持、encoded 非空、长度正确、全为 hex、全为小写。
pub fn Digest::parse(raw : String) -> Result[Digest, DigestError] {
  if raw.is_empty() {
    return Err(EmptyDigest)
  }
  let (algorithm, encoded) = match raw.find(":") {
    None => return Err(MissingSeparator(raw))
    Some(index) => (raw[:index].to_owned(), raw[index + 1:].to_owned())
  }
  if algorithm.is_empty() {
    return Err(MissingAlgorithm(raw))
  }
  if encoded.is_empty() {
    return Err(EmptyEncoded(raw))
  }
  let expected_length = match digest_hex_length(algorithm) {
    None =>
      return Err(UnsupportedAlgorithm(algorithm, supported_digest_algorithms))
    Some(length) => length
  }
  if encoded.length() != expected_length {
    return Err(InvalidLength(algorithm, expected_length, encoded.length()))
  }
  for index, ch in encoded {
    match hex_value(ch) {
      None => return Err(InvalidHexChar(algorithm, ch, index))
      Some(_) => ()
    }
    // 大写 hex 单独一类错误：调用方多半只想提示「改用小写」
    if ch >= 'A' && ch <= 'F' {
      return Err(NotLowercase(raw))
    }
  }
  Ok({ algorithm, encoded, })
}

///|
/// ASCII 小写化：digest 只允许 ASCII hex，无需处理非 ASCII 大小写映射。
fn ascii_lowercase(input : String) -> String {
  let buffer = StringBuilder()
  for ch in input {
    if ch >= 'A' && ch <= 'Z' {
      buffer.write_char(Int32::unsafe_to_char(ch.to_int() + 32))
    } else {
      buffer.write_char(ch)
    }
  }
  buffer.to_string()
}

///|
/// 按 OCI 规范把 digest 规范化为小写；无法解析的输入原样返回。
///
/// `Digest::parse` 本身拒绝大写，规范化只用于处理外部来源的宽松输入。
pub fn normalize_digest(raw : String) -> String {
  match Digest::parse(raw) {
    Ok(_) => raw
    Err(_) => {
      let lowered = ascii_lowercase(raw)
      match Digest::parse(lowered) {
        Ok(_) => lowered
        Err(_) => raw
      }
    }
  }
}

///|
/// 比较计算得到的 hex（如 sha256 结果）与期望 digest 是否一致。
///
/// 期望值可带 `sha256:` 前缀；前缀算法会被忽略，只比较 hex 部分，比较前统一小写。
pub fn digest_matches_hex(expected : String, actual_hex : String) -> Bool {
  let expected_hex = match expected.find(":") {
    Some(index) => expected[index + 1:].to_owned()
    None => expected
  }
  ascii_lowercase(expected_hex) == ascii_lowercase(actual_hex)
}

///|
/// 计算字节数据的 sha256 digest。
///
/// 依据 image-spec 推荐的 SHA-256 算法，用于校验 layer/config 摘要。
pub fn Digest::from_sha256(data : BytesView) -> Digest {
  {
    algorithm: "sha256",
    encoded: @crypto.bytes_to_hex_string(@crypto.sha256(data)),
  }
}

///|
/// 校验字节数据是否与期望 digest 一致（期望值可带 `sha256:` 前缀）。
pub fn Digest::verify_sha256(data : BytesView, expected : String) -> Bool {
  digest_matches_hex(expected, Digest::from_sha256(data).encoded)
}
