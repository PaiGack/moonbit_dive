///|
/// 候选表里的路径都是「系统装 CA 包时会出现的那些位置」。
/// 换机器（Debian / RHEL / macOS）时这里不该只有一条，否则等于悄悄绑死发行版。
test "certificate candidates cover the common distro layouts" {
  assert_true(@registry_cli.certificate_paths.length() >= 4)
  let debian = @registry_cli.certificate_paths.contains(
    "/etc/ssl/certs/ca-certificates.crt",
  )
  let redhat = @registry_cli.certificate_paths.contains(
    "/etc/pki/tls/certs/ca-bundle.crt",
  )
  assert_true(debian && redhat)
}

///|
/// `--insecure-registry` 不校验证书，也就不需要任何 CA：这条路径必须永远可用，
/// 否则自建 registry 在内网机器上连不起来。
test "insecure never depends on a CA bundle" {
  let source = @registry_cli.trust_source(insecure=true) catch {
    err => fail("trust_source(insecure) should not raise: \{err}")
  }
  assert_eq(source, @registry_cli.System)
}

///|
/// 默认路径要么给出一个真实存在的 bundle，要么老实说「用系统默认」。
/// 关键是不能抛：连不上一台机器时，用户该看到「证书在哪」，而不是一句
/// 「cannot create an HTTP client」。
test "trust source always resolves to something explicable" {
  let source = @registry_cli.trust_source() catch {
    err => fail("trust_source should not raise: \{err}")
  }
  let described = source.describe()
  assert_true(described.length() > 0)
  match source {
    @registry_cli.Bundle(path) => assert_true(path.length() > 0)
    @registry_cli.System => ()
  }
}
