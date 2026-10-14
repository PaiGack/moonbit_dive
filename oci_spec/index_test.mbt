///|
test "Index lists manifests and platforms" {
  let document = @oci_spec.parse_document(fixture("index.json")).unwrap()
  match document {
    IndexDoc(index) => {
      assert_eq(index.manifests.length(), 3)
      let platforms = index.platforms()
      assert_eq(platforms.length(), 3)
      inspect(
        platforms.map(platform => platform.to_string()).join(", "),
        content="linux/amd64, linux/arm64/v8, windows/amd64",
      )
    }
    _ => fail("expected an index")
  }
}

///|
test "Index::find_platform matches os and architecture" {
  let document = @oci_spec.parse_document(fixture("index.json")).unwrap()
  match document {
    IndexDoc(index) => {
      let arm64 = index.find_platform("linux", "arm64").unwrap()
      assert_eq(
        arm64.digest,
        "sha256:5b0bcabd1ed22e9fb1310cf6c2dec7cdef19f0ad69efa1f392e94a4333501270",
      )
      assert_eq(arm64.platform.unwrap().variant, Some("v8"))
      assert_eq(
        index.find_platform("linux", "riscv64").map(d => d.digest),
        None,
      )
    }
    _ => fail("expected an index")
  }
}

///|
test "Index keeps os.version for windows entries" {
  let document = @oci_spec.parse_document(fixture("index.json")).unwrap()
  match document {
    IndexDoc(index) => {
      let windows = index.find_platform("windows", "amd64").unwrap()
      assert_eq(windows.platform.unwrap().os_version, Some("10.0.20348.2113"))
    }
    _ => fail("expected an index")
  }
}

///|
test "Index round-trips through JSON" {
  let document = @oci_spec.parse_document(fixture("index.json")).unwrap()
  match document {
    IndexDoc(index) => {
      let encoded = @json.to_json(index).stringify()
      let decoded : @oci_spec.Index = @json.from_json(@json.parse(encoded))
      assert_eq(decoded, index)
    }
    _ => fail("expected an index")
  }
}

///|
test "Index rejects a descriptor without a platform-independent digest" {
  let text =
    #|{"schemaVersion": 2, "manifests": [{"mediaType": "x", "size": 1}]}
  match @oci_spec.parse_document(text) {
    Err(DecodeFailed(message)) => assert_true(message.contains("digest"))
    _ => fail("expected DecodeFailed")
  }
}

///|
test "Index::platforms skips descriptors without a platform" {
  let text =
    #|{"schemaVersion": 2, "manifests": [{"mediaType": "x", "digest": "sha256:a", "size": 1}]}
  match @oci_spec.parse_document(text) {
    Ok(IndexDoc(index)) => assert_eq(index.platforms().length(), 0)
    _ => fail("expected an index")
  }
}
