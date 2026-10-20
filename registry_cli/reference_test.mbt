///|
/// 解析必须失败，且错误是「引用不合法」。
fn expect_invalid(raw : String) -> Bool {
  try @registry_cli.parse_reference(raw) |> ignore catch {
    @registry_cli.InvalidReference(_) => return true
    _ => ()
  } noraise {
    _ => ()
  }
  false
}

///|
async test "docker hub short name gets library prefix" {
  // 引用解析是纯函数，失败即用例不成立，直接 fail
  let reference = @registry_cli.parse_reference("nginx") catch {
    _ => fail("reference should parse")
  }
  assert_eq(reference.registry, "")
  assert_eq(reference.repository, "library/nginx")
  assert_eq(reference.reference, "latest")
  assert_eq(reference.api_host(), "registry-1.docker.io")
}

///|
async test "explicit tag is kept" {
  let reference = @registry_cli.parse_reference("nginx:1.27") catch {
    _ => fail("reference should parse")
  }
  assert_eq(reference.repository, "library/nginx")
  assert_eq(reference.reference, "1.27")
  assert_false(reference.is_digest())
}

///|
async test "org image keeps its path" {
  let reference = @registry_cli.parse_reference("moonbitlang/dive:0.1") catch {
    _ => fail("reference should parse")
  }
  assert_eq(reference.registry, "")
  assert_eq(reference.repository, "moonbitlang/dive")
  assert_eq(reference.reference, "0.1")
}

///|
async test "registry host is separated by a dot" {
  let reference = @registry_cli.parse_reference("ghcr.io/owner/repo:tag") catch {
    _ => fail("reference should parse")
  }
  assert_eq(reference.registry, "ghcr.io")
  assert_eq(reference.repository, "owner/repo")
  assert_eq(reference.api_host(), "ghcr.io")
  assert_eq(reference.reference, "tag")
}

///|
async test "registry with a port keeps the port out of the tag" {
  let reference = @registry_cli.parse_reference("localhost:5000/library/nginx") catch {
    _ => fail("reference should parse")
  }
  assert_eq(reference.registry, "localhost:5000")
  assert_eq(reference.repository, "library/nginx")
  // 冒号属于端口，不能当成 tag 的分隔符
  assert_eq(reference.reference, "latest")
  let tagged = @registry_cli.parse_reference("localhost:5000/library/nginx:1.0") catch {
    _ => fail("reference should parse")
  }
  assert_eq(tagged.registry, "localhost:5000")
  assert_eq(tagged.reference, "1.0")
}

///|
async test "digest reference wins over tag" {
  let digest = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  let reference = @registry_cli.parse_reference("nginx@\{digest}") catch {
    _ => fail("reference should parse")
  }
  assert_eq(reference.repository, "library/nginx")
  assert_eq(reference.reference, digest)
  assert_true(reference.is_digest())
}

///|
async test "canonical renders the full name" {
  let reference = @registry_cli.parse_reference("nginx:latest") catch {
    _ => fail("reference should parse")
  }
  assert_eq(reference.canonical(), "registry-1.docker.io/library/nginx:latest")
  let digest = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  let pinned = @registry_cli.parse_reference("nginx@\{digest}") catch {
    _ => fail("reference should parse")
  }
  assert_eq(pinned.canonical(), "registry-1.docker.io/library/nginx@\{digest}")
}

///|
async test "empty reference is rejected" {
  assert_true(expect_invalid(""))
  assert_true(expect_invalid("   "))
}

///|
async test "url scheme is rejected with a hint" {
  let error = try
    @registry_cli.parse_reference("https://ghcr.io/owner/repo:tag")
  catch {
    error => error
  } noraise {
    _ => fail("expected a failure")
  }
  match error {
    @registry_cli.InvalidReference(message) =>
      assert_true(message.contains("scheme"))
    _ => fail("expected InvalidReference")
  }
}

///|
async test "bad digest is rejected" {
  assert_true(expect_invalid("nginx@sha256:beef"))
}

///|
async test "uppercase repository is rejected" {
  let error = try @registry_cli.parse_reference("Library/Nginx") catch {
    error => error
  } noraise {
    _ => fail("expected a failure")
  }
  match error {
    @registry_cli.InvalidReference(message) =>
      assert_true(message.contains("lowercase"))
    _ => fail("expected InvalidReference")
  }
}

///|
async test "empty path segments are rejected" {
  assert_true(expect_invalid("ghcr.io//repo"))
  assert_true(expect_invalid("ghcr.io/repo/"))
}
