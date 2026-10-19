///|
/// 拉取远端镜像时可能出的错。
///
/// 分类原则与 P5 的 `DockerCliError` 一致：**人话** + 能让调用方判定的形状。
/// 尤其 `NotFound` 与 `Auth` 必须分开——前者是「名字写错了」，
/// 后者是「凭据不对」，把两者混成一句 "failed" 只会让人两边都查。
pub(all) suberror RegistryError {
  /// 镜像引用本身不合法（空、`:` 太多、仓库名带大写等）
  InvalidReference(String)
  /// 401 / 403：token 换不到，或换到的 token 被拒
  Auth(String)
  /// manifest / blob 的 404：仓库名或引用写错，或者平台没有这个镜像
  NotFound(String)
  /// 结构不认识：manifest 类型没实现、index 里找不到匹配的平台、层压缩方式不支持
  Unsupported(String)
  /// 下下来的字节和 digest 对不上（传输损坏，或对方在骗人）
  DigestMismatch(String)
  /// 连不上 / 超时 / 重定向异常 / 响应读一半断了
  Network(String)
  /// 落盘失败
  Io(String)
} derive(Eq, Debug)

///|
pub extend RegistryError with Eq::{equal, not_equal}

///|
pub extend RegistryError with @debug.Debug::{to_repr}

///|
/// 错误信息面向用户：先说哪里错了，再给出可执行的下一步。
pub impl Show for RegistryError with fn to_string(self) {
  match self {
    InvalidReference(detail) =>
      "invalid image reference: \{detail}\n" +
      "  expected something like nginx:latest, library/nginx:1.27 or ghcr.io/owner/repo:tag"
    Auth(detail) =>
      "registry authentication failed: \{detail}\n" +
      "  a 401 on a manifest can also mean the repository does not exist (Docker Hub\n" +
      "  answers 401 for missing repositories); check the name, then set\n" +
      "  DIVE_REGISTRY_TOKEN=<token> (or --registry-token) if it is private"
    NotFound(detail) =>
      "not found in the registry: \{detail}\n" +
      "  check the repository name and the tag/digest; `library/` is implied for Docker Hub"
    Unsupported(detail) => "unsupported by this client: \{detail}"
    DigestMismatch(detail) => "content does not match its digest: \{detail}"
    Network(detail) => "network error while talking to the registry: \{detail}"
    Io(detail) => "cannot write the archive: \{detail}"
  }
}

///|
pub extend RegistryError with Show::{to_string, output}
