///|
test "ImageConfig parses created, author and platform" {
  let document = @oci_spec.parse_document(fixture("config.json"))
  match document {
    ImageConfig(config) => {
      assert_eq(config.os, Some("linux"))
      assert_eq(config.architecture, Some("amd64"))
      assert_eq(config.created, Some("2024-04-01T00:00:00.000000000Z"))
      assert_eq(
        config.author,
        Some("Example Maintainer <maintainer@example.com>"),
      )
      assert_eq(config.platform().to_string(), "linux/amd64")
    }
    _ => fail("expected an image config")
  }
}

///|
test "ImageConfig parses rootfs diff_ids" {
  let document = @oci_spec.parse_document(fixture("config.json"))
  match document {
    ImageConfig(config) => {
      assert_eq(config.rootfs.fs_type, "layers")
      assert_eq(config.rootfs.diff_ids.length(), 2)
      assert_eq(
        config.rootfs.diff_ids[0],
        "sha256:6f6ea4c1d9a0cbb7a6d9e1d6f7c4e9b6f0bd7d86a1f0e4b8b7a56d5e5a0c0a11",
      )
    }
    _ => fail("expected an image config")
  }
}

///|
test "ImageConfig history keeps empty_layer flags" {
  let document = @oci_spec.parse_document(fixture("config.json"))
  match document {
    ImageConfig(config) => {
      assert_eq(config.history.length(), 3)
      assert_eq(config.layer_history().length(), 2)
      assert_eq(config.history[1].empty_layer, true)
      assert_eq(config.history[1].created_by, Some("ENV PATH=/usr/local/sbin"))
    }
    _ => fail("expected an image config")
  }
}

///|
test "ImageConfig::layers pairs diff_ids with history commands" {
  let document = @oci_spec.parse_document(fixture("config.json"))
  match document {
    ImageConfig(config) => {
      let layers = config.layers()
      assert_eq(layers.length(), 2)
      assert_eq(layers[0].index, 0)
      assert_eq(layers[0].created_by, Some("COPY / / # buildkit"))
      assert_eq(
        layers[1].created_by,
        Some("RUN /bin/sh -c apt-get update # buildkit"),
      )
      assert_true(layers[0].diff_id.has_prefix("sha256:"))
    }
    _ => fail("expected an image config")
  }
}

///|
test "ContainerConfig exposes common runtime keys" {
  let document = @oci_spec.parse_document(fixture("config.json"))
  match document {
    ImageConfig(config) => {
      let runtime = config.config.unwrap()
      assert_eq(runtime.cmd(), ["/bin/sh", "-c", "echo hello"])
      assert_eq(runtime.entrypoint(), ["/entrypoint.sh"])
      assert_eq(runtime.working_dir(), Some("/app"))
      assert_eq(runtime.user(), Some("1000:1000"))
    }
    _ => fail("expected an image config")
  }
}

///|
test "ImageConfig rootfs is required" {
  let text =
    #|{"schemaVersion": 2, "os": "linux"}
  let result = try @oci_spec.parse_document(text) catch {
    err => err
  } noraise {
    _ => abort("expected an error")
  }
  match result {
    DecodeFailed(message) => {
      assert_true(message.contains("rootfs"))
      assert_true(message.contains("missing required field"))
    }
    _ => fail("expected DecodeFailed")
  }
}

///|
test "ImageConfig rejects a wrong diff_ids element type" {
  let text =
    #|{"schemaVersion": 2, "rootfs": {"type": "layers", "diff_ids": ["ok", 42]}}
  let result = try @oci_spec.parse_document(text) catch {
    err => err
  } noraise {
    _ => abort("expected an error")
  }
  match result {
    DecodeFailed(message) => assert_true(message.contains("expected string"))
    _ => fail("expected DecodeFailed")
  }
}

///|
test "ImageConfig history defaults to empty when absent" {
  let text =
    #|{"schemaVersion": 2, "rootfs": {"type": "layers", "diff_ids": []}, "history": []}
  match @oci_spec.parse_document(text) {
    ImageConfig(config) => {
      assert_eq(config.history.length(), 0)
      assert_eq(config.config, None)
    }
    _ => fail("expected an image config")
  }
}

///|
test "ImageConfig round-trips through JSON" {
  let document = @oci_spec.parse_document(fixture("config.json"))
  match document {
    ImageConfig(config) => {
      let encoded = @json.to_json(config).stringify()
      let decoded : @oci_spec.ImageConfig = @json.from_json(
        @json.parse(encoded),
      )
      assert_eq(decoded, config)
    }
    _ => fail("expected an image config")
  }
}

///|
test "Platform matching treats unset fields as wildcards" {
  let document = @oci_spec.parse_document(fixture("index.json"))
  match document {
    IndexDoc(index) => {
      let platform = index.find_platform("linux", "amd64").unwrap().platform.unwrap()
      assert_true(platform.matches("linux", "amd64"))
      assert_false(platform.matches("windows", "amd64"))
      assert_false(platform.is_empty())
      let empty : @oci_spec.Platform = {
        architecture: "",
        os: "",
        os_version: None,
        os_features: None,
        variant: None,
      }
      assert_true(empty.is_empty())
      assert_true(empty.matches("linux", "amd64"))
    }
    _ => fail("expected an index")
  }
}
