///|
test "parse_document recognizes an OCI manifest" {
  let document = @oci_spec.parse_document(fixture("manifest.json")).unwrap()
  match document {
    Manifest(manifest) => {
      assert_eq(manifest.schema_version, 2)
      assert_eq(
        manifest.media_type,
        Some("application/vnd.oci.image.manifest.v1+json"),
      )
      assert_eq(manifest.layers.length(), 2)
    }
    _ => fail("expected a manifest")
  }
}

///|
test "parse_document recognizes an OCI index" {
  let document = @oci_spec.parse_document(fixture("index.json")).unwrap()
  match document {
    IndexDoc(index) => {
      assert_eq(index.manifests.length(), 3)
      assert_eq(index.platforms().length(), 3)
    }
    _ => fail("expected an index")
  }
}

///|
test "parse_document recognizes an image config even without a leading mediaType" {
  // config.json 的 mediaType 在末尾，判别仍应命中 config
  let document = @oci_spec.parse_document(fixture("config.json")).unwrap()
  match document {
    ImageConfig(config) => {
      assert_eq(config.os, Some("linux"))
      assert_eq(config.rootfs.diff_ids.length(), 2)
    }
    _ => fail("expected an image config")
  }
}

///|
test "parse_document recognizes a docker manifest by media type" {
  let document = @oci_spec.parse_document(fixture("docker_manifest.json")).unwrap()
  match document {
    Manifest(manifest) => {
      assert_true(
        @oci_spec.is_manifest_media_type(manifest.media_type.unwrap()),
      )
      assert_eq(manifest.layers.length(), 1)
    }
    _ => fail("expected a manifest")
  }
}

///|
test "parse_document reports JSON syntax errors" {
  assert_true(@oci_spec.parse_document("{not json") is Err(ParseFailed(_)))
}

///|
test "parse_document rejects a non-object top level" {
  match @oci_spec.parse_document("[1, 2, 3]") {
    Err(NotAnObject(actual)) => inspect(actual, content="[1,2,3]")
    _ => fail("expected NotAnObject")
  }
}

///|
test "parse_document reports the offending field path" {
  let text =
    #|{"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {}, "layers": []}
  match @oci_spec.parse_document(text) {
    Err(DecodeFailed(message)) => {
      // config 里缺 mediaType/digest/size
      assert_true(message.contains("mediaType"))
      assert_true(message.contains("missing required field"))
    }
    other => assert_true(other is Err(_))
  }
}

///|
test "parse_document rejects a wrong field type" {
  let text =
    #|{"schemaVersion": "two", "mediaType": "application/vnd.oci.image.manifest.v1+json"}
  match @oci_spec.parse_document(text) {
    Err(DecodeFailed(message)) => {
      assert_true(message.contains("expected integer"))
      assert_true(message.contains("/schemaVersion"))
    }
    other => assert_true(other is Err(_))
  }
}

///|
test "parse_image_config_lenient fills in a missing schemaVersion" {
  let text =
    #|{"os": "linux", "architecture": "amd64", "rootfs": {"type": "layers", "diff_ids": []}, "history": []}
  let config = @oci_spec.parse_image_config_lenient(text).unwrap()
  assert_eq(config.schema_version, 2)
  assert_eq(config.os, Some("linux"))
}

///|
test "parse_document sniffs the kind when mediaType is absent" {
  let index_text =
    #|{"schemaVersion": 2, "manifests": []}
  assert_true(@oci_spec.parse_document(index_text).unwrap() is IndexDoc(_))
  let manifest_text =
    #|{"schemaVersion": 2, "config": {"mediaType": "x", "digest": "sha256:a", "size": 1}, "layers": []}
  assert_true(@oci_spec.parse_document(manifest_text).unwrap() is Manifest(_))
}
