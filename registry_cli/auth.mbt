///|
/// `WWW-Authenticate: Bearer realm="...",service="...",scope="..."` 的解析结果。
///
/// registry 只在第一次裸请求时回这个头，之后就该拿着 token 走了；
/// 所以这里只需要「把挑战读懂」，不需要实现完整的认证协商。
pub(all) struct AuthChallenge {
  /// `Basic` 还是 `Bearer`
  scheme : String
  /// token 端点（Bearer 才有）
  realm : String
  /// token 服务名（Bearer 才有）
  service : String
  /// 申请的权限范围，例如 `repository:library/nginx:pull`
  scope : String
} derive(Eq, Debug)

///|
pub extend AuthChallenge with Eq::{equal, not_equal}

///|
pub extend AuthChallenge with @debug.Debug::{to_repr}

///|
/// 从 `WWW-Authenticate` 的值里解析挑战。解析不出来返回 `None`——
/// 调用方据此报「认证失败但看不懂对方要什么」，而不是瞎猜。
pub fn parse_challenge(header : String) -> AuthChallenge? {
  let text : String = header.trim().to_owned()
  let (scheme, rest) = match text.find(" ") {
    None => (text, "")
    Some(index) =>
      (text[:index].to_lower().to_owned(), text[index + 1:].to_owned())
  }
  if scheme != "bearer" && scheme != "basic" {
    return None
  }
  let fields = parse_auth_params(rest)
  let realm = match fields.get("realm") {
    Some(realm) => realm
    None => ""
  }
  Some({
    scheme,
    realm,
    service: fields.get("service").unwrap_or(""),
    scope: fields.get("scope").unwrap_or(""),
  })
}

///|
/// 拆 `k="v", k2="v2"`：引号里的逗号不算分隔符（scope 里会有逗号）。
fn parse_auth_params(text : String) -> Map[String, String] {
  let fields : Map[String, String] = Map([])
  let mut key = ""
  let mut value = ""
  let buffer = StringBuilder()
  let mut in_quotes = false
  let mut after_value = false
  for ch in text {
    if in_quotes {
      if ch == '"' {
        in_quotes = false
        after_value = true
        value = buffer.to_string()
        buffer.reset()
      } else {
        buffer.write_char(ch)
      }
      continue
    }
    if ch == '"' {
      in_quotes = true
      continue
    }
    if ch == '=' {
      key = buffer.to_string().trim().to_lower().to_owned()
      buffer.reset()
      // 接下来是值：加引号的在下面走 in_quotes，不加引号的到这里直接收
      continue
    }
    if ch == ',' {
      // 字段收口：加引号的值存在 `value`，未加引号的值还在 `buffer` 里
      if !key.is_empty() {
        if after_value {
          fields.set(key, value)
        } else {
          let raw = buffer.to_string().trim().to_owned()
          if !raw.is_empty() {
            fields.set(key, raw)
          }
        }
      }
      key = ""
      value = ""
      after_value = false
      buffer.reset()
      continue
    }
    buffer.write_char(ch)
  }
  // 未加引号的最后一个值：`realms=...` 走到这里才收尾
  if !key.is_empty() {
    let raw = buffer.to_string().trim().to_owned()
    if after_value {
      fields.set(key, value)
    } else if !raw.is_empty() {
      fields.set(key, raw)
    }
  }
  fields
}

///|
/// 一次拉取用到的凭据。
///
/// 现在只支持两种：匿名（走 token 端点的匿名换票）与显式 token
/// （`DIVE_REGISTRY_TOKEN` / `--registry-token`）。Basic 账号密码
/// 留着枚举位但**没有实现**：真要支持得先有安全的落盘方式，见文档。
pub(all) enum RegistryCredentials {
  Anonymous
  /// 直接当 `Authorization: Bearer <token>` 用
  Bearer(String)
} derive(Eq, Debug)

///|
pub extend RegistryCredentials with Eq::{equal, not_equal}

///|
pub extend RegistryCredentials with @debug.Debug::{to_repr}

///|
pub impl Show for RegistryCredentials with fn to_string(self) {
  match self {
    Anonymous => "anonymous"
    // 凭据不进日志、不进报错：只说「有」
    Bearer(_) => "bearer token"
  }
}

///|
pub extend RegistryCredentials with Show::{to_string, output}
