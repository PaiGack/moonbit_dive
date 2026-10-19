///|
test "bearer challenge is parsed" {
  let challenge = @registry_cli.parse_challenge(
    "Bearer realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\",scope=\"repository:library/nginx:pull\"",
  ).unwrap()
  assert_eq(challenge.scheme, "bearer")
  assert_eq(challenge.realm, "https://auth.docker.io/token")
  assert_eq(challenge.service, "registry.docker.io")
  assert_eq(challenge.scope, "repository:library/nginx:pull")
}

///|
test "challenge scope may contain commas" {
  let challenge = @registry_cli.parse_challenge(
    "Bearer realm=\"https://auth.example.com/token\",scope=\"repository:a/b:pull,push\"",
  ).unwrap()
  // 引号里的逗号是 scope 的一部分，不能当字段分隔符
  assert_eq(challenge.scope, "repository:a/b:pull,push")
}

///|
test "challenge fields may be unquoted" {
  let challenge = @registry_cli.parse_challenge(
    "Bearer realm=https://auth.example.com/token,service=example",
  ).unwrap()
  assert_eq(challenge.realm, "https://auth.example.com/token")
  // 未加引号的字段走 after_value 分支，值必须真的被记下来
  assert_eq(challenge.service, "example")
}

///|
test "basic challenge is recognised" {
  let challenge = @registry_cli.parse_challenge("Basic realm=\"registry\"").unwrap()
  assert_eq(challenge.scheme, "basic")
  assert_eq(challenge.realm, "registry")
}

///|
test "unknown scheme is not a challenge" {
  assert_true(@registry_cli.parse_challenge("Negotiate") is None)
  assert_true(@registry_cli.parse_challenge("") is None)
}

///|
test "credentials do not leak the token in Show" {
  let credentials = @registry_cli.Bearer("super-secret-token")
  let rendered = credentials.to_string()
  assert_false(rendered.contains("super-secret-token"))
  assert_eq(@registry_cli.Anonymous.to_string(), "anonymous")
}
