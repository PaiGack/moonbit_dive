///|
/// 本进程可用的 TLS 根证书。
///
/// `moonbitlang/async` 的 `@tls.SystemRoot` 走 OpenSSL 的
/// `SSL_CTX_set_default_verify_paths`，后者**只在系统装了 CA 包时**才成功
/// （Debian 系是 `ca-certificates`）。缺了它，`@http.Client` 的构造函数直接抛，
/// 表现是 `cannot create an HTTP client for <host>`——一句话把「机器没装 CA 包」
/// 说成「连不上 registry」，`--from-image` 那条已经不依赖网络的通路也跟着红掉。
///
/// 所以这里把「证书到底在哪」摊开：能读到一份就用它，实在没有才退到系统默认。
/// 找到的那条路径会随报告一起打出来，排查时不用猜。
pub let certificate_paths : Array[String] = [
  "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem",
  "/etc/ssl/ca-bundle.pem", "/usr/local/share/certs/ca-root-nss.crt", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
]

///|
/// 本机能用的根证书来源。
///
/// - `Bundle(path)`：这个文件在，里面是 PEM，直接交给 OpenSSL 用
/// - `System`：找不到任何候选，只能指望 `SSL_CTX_set_default_verify_paths`
pub(all) enum TrustSource {
  Bundle(String)
  System
} derive(Eq, Debug)

///|
pub extend TrustSource with Eq::{equal, not_equal}

///|
pub extend TrustSource with @debug.Debug::{to_repr}

///|
/// 选一个根证书来源。`insecure`（`--insecure-registry`）不校验，没有来源也无所谓。
///
/// 明确给了 `DIVE_CA_BUNDLE` 就只用它：那说明用户知道自己要什么，
/// 文件不在就直接报错，别偷偷退回到别的 bundle——退回去的后果是
/// 「换了个根证书，报的错误与没设时一模一样」。
pub fn trust_source(
  insecure~ : Bool = false,
) -> TrustSource raise RegistryError {
  if insecure {
    return System
  }
  match @env.get_env_var("DIVE_CA_BUNDLE") {
    Some(path) if !path.is_empty() => {
      if !file_exists(path) {
        raise Io("DIVE_CA_BUNDLE points at \{path}, which is missing or empty")
      }
      return Bundle(path)
    }
    _ => ()
  }
  for path in certificate_paths {
    if file_exists(path) {
      return Bundle(path)
    }
  }
  System
}

///|
/// 文件在且非空。读它是为了判断「有条目但为空」——空 bundle 交给 OpenSSL
/// 会退化成「没有任何根证书」，症状与文件不存在一样难查。
fn file_exists(path : String) -> Bool {
  let is_file = @xfs.is_file(path) catch { _ => false }
  if !is_file {
    return false
  }
  let size = @xfs.read_file_to_bytes(path) catch {
    _ => Bytes::make(0, b'\x00')
  }
  size.length() > 0
}

///|
/// 把来源翻成人话，用在错误里（别让用户去猜「哪个 bundle 才算数」）。
pub fn TrustSource::describe(self : TrustSource) -> String {
  match self {
    Bundle(path) => path
    System => "the system default (SSL_CTX_set_default_verify_paths)"
  }
}
