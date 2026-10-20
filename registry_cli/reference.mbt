///|
/// 一个已解析的镜像引用：`[registry/]repository[:tag][@digest]`。
///
/// 拆开存是因为三段的缺省规则各不相同，混在一个字符串里每次用都要重新猜：
/// - registry：没写就是 Docker Hub（`docker.io`），但**请求**要走 `registry-1.docker.io`
/// - repository：Docker Hub 上单段名字要补 `library/` 前缀
/// - reference：tag 与 digest 二选一，都没写按 `latest`
pub(all) struct ImageReference {
  /// 用户实际写的 registry（可能为空）
  registry : String
  /// 补全后的仓库路径，例如 `library/nginx`
  repository : String
  /// tag 或 digest（`sha256:...`），二选一
  reference : String
  /// 用户原始写法，报告里要能原样打回去
  original : String
} derive(Eq, Debug)

///|
pub extend ImageReference with Eq::{equal, not_equal}

///|
pub extend ImageReference with @debug.Debug::{to_repr}

///|
pub impl Show for ImageReference with fn to_string(self) {
  self.original
}

///|
pub extend ImageReference with Show::{to_string, output}

///|
/// Docker Hub 的两种域名：用户写的通常是 `docker.io`，
/// 真正提供 Registry API 的是 `registry-1.docker.io`。
pub let docker_hub_registry : String = "docker.io"

///|
pub let docker_hub_api_host : String = "registry-1.docker.io"

///|
/// 引用里的 `reference` 是不是 digest（而非 tag）。
pub fn ImageReference::is_digest(self : ImageReference) -> Bool {
  self.reference.contains(":")
}

///|
/// 请求要打到哪个 host：Docker Hub 换成它的 API 域名，其余原样。
pub fn ImageReference::api_host(self : ImageReference) -> String {
  if self.registry.is_empty() || self.registry == docker_hub_registry {
    docker_hub_api_host
  } else {
    self.registry
  }
}

///|
/// 报告里显示用的完整名字（`reg/repo:tag`）。
pub fn ImageReference::canonical(self : ImageReference) -> String {
  if self.is_digest() {
    "\{self.api_host()}/\{self.repository}@\{self.reference}"
  } else {
    "\{self.api_host()}/\{self.repository}:\{self.reference}"
  }
}

///|
/// 解析镜像引用。
///
/// 规则与 docker 的「熟悉的那套」对齐，只实现被验证过的那几条：
/// - 第一个 `/` 之前若含 `.` 或 `:`，或者就是 `localhost`，那它就是 registry
/// - Docker Hub 上单段仓库名补 `library/`（`nginx` → `library/nginx`）
/// - `@digest` 优先于 `:tag`；都没有按 `latest`
///
/// 不做的：仓库名大小写宽容（OCI 要求全小写，写错就该报错而不是偷偷改名）。
pub fn parse_reference(raw : String) -> ImageReference raise RegistryError {
  let original = raw.trim().to_owned()
  if original.is_empty() {
    raise InvalidReference("reference is empty")
  }
  if original.contains("://") {
    raise InvalidReference(
      "\"{original}\" looks like a URL; drop the scheme (https://) and pass reg/repo:tag",
    )
  }
  let (rest, reference) = match original.find("@") {
    Some(index) => {
      let digest = original[index + 1:].to_owned()
      let _ = @oci_spec.Digest::parse(digest) catch {
        err => raise InvalidReference(err.to_string())
      }
      (original[:index].to_owned(), digest)
    }
    None => split_tag(original)
  }
  if rest.is_empty() {
    raise InvalidReference("reference \"\{original}\" has no repository")
  }
  let (registry, repository) = split_registry(rest)
  if repository.is_empty() {
    raise InvalidReference(
      "\"{original}\" has no repository after the registry",
    )
  }
  check_repository(repository)
  { registry, repository, reference, original, }
}

///|
/// 拆 `name[:tag]`：只看最后一个 `:`，且它后面不能有 `/`
/// （否则那个冒号属于 registry 的端口）。
fn split_tag(text : String) -> (String, String) {
  // 最后一个 `/` 之后的才是名字本体：它前面的冒号属于 registry 端口
  let from = match text.rev_find("/") {
    None => 0
    Some(slash) => slash + 1
  }
  match_tag_at_end(text, from)
}

///|
fn match_tag_at_end(text : String, from : Int32) -> (String, String) {
  match text[from:].find(":") {
    Some(offset) => {
      let index = from + offset
      let tag = text[index + 1:].to_owned()
      if tag.is_empty() {
        (text, "latest")
      } else {
        (text[:index].to_owned(), tag)
      }
    }
    None => (text, "latest")
  }
}

///|
/// 第一个 `/` 之前的那段如果是 registry 就分开：含 `.` / `:`，或者是 `localhost`。
fn split_registry(text : String) -> (String, String) {
  let slash = match text.find("/") {
    // 没有斜杠：整条就是一个 Docker Hub 上的短名，要补 `library/`
    None => return ("", "library/\{text}")
    Some(index) => index
  }
  let head = text[:slash].to_owned()
  let tail = text[slash + 1:].to_owned()
  let is_registry = head == "localhost" ||
    head.contains(".") ||
    head.contains(":")
  if is_registry {
    (head, tail)
  } else if text.contains("/") {
    // 多段路径（`owner/repo`）本身就是完整仓库名
    ("", text)
  } else {
    // 单段名字在 Docker Hub 上要补 `library/`：`nginx` 与 `library/nginx` 是同一个
    ("", "library/\{text}")
  }
}

///|
/// 仓库路径的字符检查：OCPI 规范是 `[a-z0-9]+` 分段，用 `.` `_` `__` `-` 连接。
/// 只挡明显的错（大写、空格、连续斜杠），不做全量正则——报错要能看懂。
fn check_repository(repository : String) -> Unit raise RegistryError {
  if repository.has_prefix("/") || repository.has_suffix("/") {
    raise InvalidReference(
      "repository \"\{repository}\" starts or ends with \"/\"",
    )
  }
  if repository.contains("//") {
    raise InvalidReference(
      "repository \"\{repository}\" has an empty path segment",
    )
  }
  for ch in repository {
    if ch >= 'A' && ch <= 'Z' {
      raise InvalidReference(
        "repository \"\{repository}\" must be lowercase (OCI names are lowercase)",
      )
    }
    if ch == ' ' {
      raise InvalidReference("repository \"\{repository}\" contains a space")
    }
  }
}
