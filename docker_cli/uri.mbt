///|
/// 解析过的 `unix://` 地址。
pub(all) struct UnixUri {
  path : String
  /// `http://host/path` 形式的 Host 头，Docker Engine 在 unix socket 上
  /// 默认用 `localhost`；留成字段便于后续支持 `DOCKER_CONTEXT`。
  host : String
} derive(Eq, Debug)

///|
pub extend UnixUri with Eq::{equal, not_equal}

///|
pub extend UnixUri with @debug.Debug::{to_repr}

///|
/// `unix:///var/run/docker.sock` → `{path: "/var/run/docker.sock", host: "localhost"}`。
///
/// 只接受 `unix://`；`tcp://` / `ssh://` / npipe 属于后续 issue，
/// 这里返回 `None` 让探测继续往下走，而不是给个半成品实现。
pub fn parse_unix_uri(host : String) -> UnixUri? {
  let trimmed = host.trim()
  if !trimmed.has_prefix("unix://") {
    return None
  }
  let rest = trimmed[7:].to_owned()
  if rest.is_empty() {
    return None
  }
  // `unix://` 后面允许有 `` 或 `localhost` 作为 authority，路径一律以 `/` 开头
  let path = if rest.has_prefix("/") {
    rest
  } else {
    match rest.find("/") {
      Some(index) => rest[index:].to_owned()
      None => return None
    }
  }
  if path.is_empty() {
    None
  } else {
    Some({ path, host: "localhost", })
  }
}
