///|
let sha256_hex : String = "e692418e4cbaf90ca69d05a66403747baa33ee08806650b51fab815ad7fc331f"

///|
let sha256_digest : String = "sha256:e692418e4cbaf90ca69d05a66403747baa33ee08806650b51fab815ad7fc331f"

///|
/// 手工大写化，避免依赖 core 的具体大写 API。
fn upper(input : String) -> String {
  let buffer = StringBuilder()
  for ch in input {
    buffer.write_char(
      if ch >= 'a' && ch <= 'z' {
        Int32::unsafe_to_char(ch.to_int() - 32)
      } else {
        ch
      },
    )
  }
  buffer.to_string()
}

///|
test "Digest::parse accepts a well-formed sha256 digest" {
  let digest = @oci_spec.Digest::parse(sha256_digest).unwrap()
  assert_eq(digest.algorithm, "sha256")
  assert_eq(digest.encoded, sha256_hex)
  assert_eq(digest.to_string(), sha256_digest)
}

///|
test "Digest::parse accepts sha512" {
  let hex = "a".repeat(128)
  let digest = @oci_spec.Digest::parse("sha512:\{hex}").unwrap()
  assert_eq(digest.algorithm, "sha512")
  assert_eq(digest.encoded.length(), 128)
}

///|
test "Digest::parse rejects empty input" {
  assert_true(@oci_spec.Digest::parse("") is Err(EmptyDigest))
}

///|
test "Digest::parse rejects a digest without a colon" {
  assert_true(@oci_spec.Digest::parse(sha256_hex) is Err(MissingSeparator(_)))
}

///|
test "Digest::parse rejects a missing algorithm part" {
  assert_true(
    @oci_spec.Digest::parse(":\{sha256_hex}") is Err(MissingAlgorithm(_)),
  )
}

///|
test "Digest::parse rejects a missing encoded part" {
  assert_true(@oci_spec.Digest::parse("sha256:") is Err(EmptyEncoded(_)))
}

///|
test "Digest::parse rejects an unknown algorithm" {
  match @oci_spec.Digest::parse("sha1:\{sha256_hex}") {
    Err(@oci_spec.UnsupportedAlgorithm(algorithm, supported)) => {
      assert_eq(algorithm, "sha1")
      assert_eq(supported, ["sha256", "sha512"])
    }
    _ => fail("expected UnsupportedAlgorithm")
  }
}

///|
test "Digest::parse rejects wrong encoded length" {
  match @oci_spec.Digest::parse("sha256:abc") {
    Err(@oci_spec.InvalidLength(algorithm, expected, actual)) => {
      assert_eq(algorithm, "sha256")
      assert_eq(expected, 64)
      assert_eq(actual, 3)
    }
    _ => fail("expected InvalidLength")
  }
}

///|
test "Digest::parse rejects non-hex characters" {
  let bad = "sha256:" + "z".repeat(63) + "0"
  match @oci_spec.Digest::parse(bad) {
    Err(@oci_spec.InvalidHexChar(algorithm, ch, index)) => {
      assert_eq(algorithm, "sha256")
      assert_eq(ch, 'z')
      assert_eq(index, 0)
    }
    _ => fail("expected InvalidHexChar")
  }
}

///|
test "Digest::parse rejects uppercase and mixed-case hex" {
  assert_true(
    @oci_spec.Digest::parse("sha256:\{upper(sha256_hex)}")
    is Err(NotLowercase(_)),
  )
  let mixed = upper(sha256_hex[:2].to_owned()) + sha256_hex[2:].to_owned()
  assert_true(
    @oci_spec.Digest::parse("sha256:\{mixed}") is Err(NotLowercase(_)),
  )
}

///|
test "Digest::parse reports the algorithm error before hex errors" {
  assert_true(
    @oci_spec.Digest::parse("sha1:zzzz") is Err(UnsupportedAlgorithm(_, _)),
  )
}

///|
test "DigestError messages are human readable" {
  assert_eq(@oci_spec.DigestError::EmptyDigest.to_string(), "digest is empty")
  inspect(
    @oci_spec.MissingSeparator("deadbeef").to_string(),
    content="digest \"deadbeef\" has no \"algorithm:encoded\" separator",
  )
  inspect(
    @oci_spec.InvalidLength("sha256", 64, 3).to_string(),
    content="sha256 digest must be 64 hex characters, got 3",
  )
  inspect(
    @oci_spec.NotLowercase("sha256:ABC").to_string(),
    content="digest \"sha256:ABC\" must use lowercase hex characters",
  )
}

///|
test "normalize_digest lowercases only valid digests" {
  assert_eq(@oci_spec.normalize_digest(sha256_digest), sha256_digest)
  assert_eq(
    @oci_spec.normalize_digest("sha256:\{upper(sha256_hex)}"),
    sha256_digest,
  )
  assert_eq(@oci_spec.normalize_digest("not-a-digest"), "not-a-digest")
}

///|
test "digest_matches_hex ignores the algorithm prefix and case" {
  assert_true(@oci_spec.digest_matches_hex(sha256_digest, sha256_hex))
  assert_true(@oci_spec.digest_matches_hex(sha256_hex, sha256_hex))
  assert_true(
    @oci_spec.digest_matches_hex("sha256:\{upper(sha256_hex)}", sha256_hex),
  )
  assert_false(@oci_spec.digest_matches_hex(sha256_digest, "0".repeat(64)))
}

///|
test "Digest::from_sha256 matches the known sha256 of hello" {
  let data = b"hello"
  // sha256("hello")
  let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  let digest = @oci_spec.Digest::from_sha256(data)
  assert_eq(digest.algorithm, "sha256")
  assert_eq(digest.encoded, expected)
  assert_true(@oci_spec.Digest::verify_sha256(data, "sha256:\{expected}"))
  assert_false(@oci_spec.Digest::verify_sha256(data, sha256_digest))
}

///|
test "Digest round-trips through JSON" {
  let digest = @oci_spec.Digest::parse(sha256_digest).unwrap()
  let json = @json.to_json(digest)
  assert_eq(json.stringify(), "\"\{sha256_digest}\"")
  let parsed : @oci_spec.Digest = @json.from_json(json)
  assert_eq(parsed, digest)
}

///|
test "Digest::from_json rejects an invalid digest" {
  let json : Json = "sha256:nothex"
  let parsed : Result[@oci_spec.Digest, String] = @json.from_json(json) catch {
    error => Err(error.to_string())
  }
  assert_true(parsed is Err(_))
}
