///|
/// 单个字符的十六进制值；非 hex 字符返回 `None`。
///
/// 大小写都接受，调用方需要区分大小写时自行判断。
pub fn hex_value(ch : Char) -> Int32? {
  if ch >= '0' && ch <= '9' {
    Some(ch.to_int() - '0'.to_int())
  } else if ch >= 'a' && ch <= 'f' {
    Some(ch.to_int() - 'a'.to_int() + 10)
  } else if ch >= 'A' && ch <= 'F' {
    Some(ch.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// 判断字符串是否只由 hex 字符组成（可指定是否必须是严格小写）。
pub fn is_hex(input : String, lowercase_only~ : Bool = false) -> Bool {
  for ch in input {
    match hex_value(ch) {
      None => return false
      Some(_) => ()
    }
    if lowercase_only && ch >= 'A' && ch <= 'F' {
      return false
    }
  }
  !input.is_empty()
}
