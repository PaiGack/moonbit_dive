///|
test "Manifest parses config and layers from a real-shaped manifest" {
  let document = @oci_spec.parse_document(fixture("manifest.json")).unwrap()
  match document {
    Manifest(manifest) => {
      assert_eq(
        manifest.config.media_type,
        "application/vnd.oci.image.config.v1+json",
      )
      assert_eq(manifest.config.size, 7023)
      assert_eq(manifest.layers.length(), 2)
      assert_eq(manifest.total_layer_size(), 32654 + 16724)
      assert_eq(
        manifest
        .layers_with_media_type("application/vnd.oci.image.layer.v1.tar+gzip")
        .length(),
        2,
      )
      assert_eq(
        manifest
        .layers_with_media_type("application/vnd.oci.image.layer.v1.tar+zstd")
        .length(),
        0,
      )
    }
    _ => fail("expected a manifest")
  }
}

///|
test "Manifest tolerates unknown fields but keeps known annotations" {
  let document = @oci_spec.parse_document(fixture("manifest.json")).unwrap()
  match document {
    Manifest(manifest) => {
      let annotations = manifest.annotations.unwrap()
      assert_eq(
        annotations["org.opencontainers.image.created"],
        "2024-04-01T00:00:00Z",
      )
      assert_eq(annotations["com.example.unknown-field"], "tolerated")
    }
    _ => fail("expected a manifest")
  }
}

///|
test "Manifest config digest validates" {
  let document = @oci_spec.parse_document(fixture("manifest.json")).unwrap()
  match document {
    Manifest(manifest) => {
      let digest = manifest.config_digest().unwrap()
      assert_eq(digest.algorithm, "sha256")
      assert_eq(
        digest.encoded,
        "b5b2b2c507a0944348e0303114d8d93aaaa081732b86451d9bce1f432a537bc7",
      )
    }
    _ => fail("expected a manifest")
  }
}

///|
test "Manifest rejects a missing required config field" {
  let text =
    #|{"schemaVersion": 2, "layers": []}
  assert_true(@oci_spec.parse_document(text) is Err(DecodeFailed(_)))
}

///|
test "Manifest rejects a wrong-typed layers field" {
  let text =
    #|{"schemaVersion": 2, "config": {"mediaType": "x", "digest": "d", "size": 1}, "layers": {"not": "an array"}}
  match @oci_spec.parse_document(text) {
    Err(DecodeFailed(message)) => {
      assert_true(message.contains("/layers"))
      assert_true(message.contains("expected array"))
    }
    _ => fail("expected DecodeFailed")
  }
}

///|
test "Manifest::is_index distinguishes index media types" {
  let manifest_text =
    #|{"schemaVersion": 2, "config": {"mediaType": "x", "digest": "d", "size": 1}, "layers": []}
  match @oci_spec.parse_document(manifest_text) {
    Ok(Manifest(manifest)) => assert_false(manifest.is_index())
    _ => fail("expected a manifest")
  }
}

///|
test "Manifest round-trips through JSON" {
  let document = @oci_spec.parse_document(fixture("manifest.json")).unwrap()
  match document {
    Manifest(manifest) => {
      let encoded = @json.to_json(manifest).stringify()
      let decoded : @oci_spec.Manifest = @json.from_json(@json.parse(encoded))
      assert_eq(decoded, manifest)
    }
    _ => fail("expected a manifest")
  }
}

///|
test "docker media types are recognized" {
  let document = @oci_spec.parse_document(fixture("docker_manifest.json")).unwrap()
  match document {
    Manifest(manifest) => {
      assert_eq(
        manifest.media_type,
        Some("application/vnd.docker.distribution.manifest.v2+json"),
      )
      assert_eq(
        manifest.config.media_type,
        "application/vnd.docker.container.image.v1+json",
      )
      assert_true(
        @oci_spec.is_layer_media_type(
          "application/vnd.docker.image.rootfs.diff.tar.gzip",
        ),
      )
      assert_false(
        @oci_spec.is_compressed_layer_media_type(
          "application/vnd.docker.image.rootfs.diff.tar",
        ),
      )
      assert_true(
        @oci_spec.is_compressed_layer_media_type(
          "application/vnd.oci.image.layer.v1.tar+zstd",
        ),
      )
    }
    _ => fail("expected a manifest")
  }
}
