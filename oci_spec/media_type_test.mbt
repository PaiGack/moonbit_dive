///|
test "media type constants match image-spec" {
  assert_eq(
    @oci_spec.oci_manifest_media_type, "application/vnd.oci.image.manifest.v1+json",
  )
  assert_eq(
    @oci_spec.oci_index_media_type, "application/vnd.oci.image.index.v1+json",
  )
  assert_eq(
    @oci_spec.oci_config_media_type, "application/vnd.oci.image.config.v1+json",
  )
  assert_eq(
    @oci_spec.oci_descriptor_media_type, "application/vnd.oci.descriptor.v1+json",
  )
  assert_eq(
    @oci_spec.docker_manifest_media_type, "application/vnd.docker.distribution.manifest.v2+json",
  )
  assert_eq(
    @oci_spec.docker_manifest_list_media_type, "application/vnd.docker.distribution.manifest.list.v2+json",
  )
  assert_eq(
    @oci_spec.docker_config_media_type, "application/vnd.docker.container.image.v1+json",
  )
  assert_eq(
    @oci_spec.docker_layer_gzip_media_type, "application/vnd.docker.image.rootfs.diff.tar.gzip",
  )
}

///|
test "manifest/index media type predicates" {
  assert_true(
    @oci_spec.is_manifest_media_type(@oci_spec.oci_manifest_media_type),
  )
  assert_true(
    @oci_spec.is_manifest_media_type(@oci_spec.docker_manifest_media_type),
  )
  assert_false(@oci_spec.is_manifest_media_type(@oci_spec.oci_index_media_type))
  assert_true(@oci_spec.is_index_media_type(@oci_spec.oci_index_media_type))
  assert_true(
    @oci_spec.is_index_media_type(@oci_spec.docker_manifest_list_media_type),
  )
  assert_false(@oci_spec.is_index_media_type(@oci_spec.oci_manifest_media_type))
}

///|
test "layer media type predicates cover ocr/docker and compression" {
  assert_true(@oci_spec.is_layer_media_type(@oci_spec.oci_layer_media_type))
  assert_true(
    @oci_spec.is_layer_media_type(@oci_spec.oci_layer_gzip_media_type),
  )
  assert_true(
    @oci_spec.is_layer_media_type(@oci_spec.oci_layer_zstd_media_type),
  )
  assert_true(
    @oci_spec.is_layer_media_type(@oci_spec.docker_layer_gzip_media_type),
  )
  assert_true(
    @oci_spec.is_layer_media_type(
      @oci_spec.docker_foreign_layer_gzip_media_type,
    ),
  )
  assert_false(@oci_spec.is_layer_media_type(@oci_spec.oci_config_media_type))
  assert_true(
    @oci_spec.is_compressed_layer_media_type(
      @oci_spec.oci_layer_gzip_media_type,
    ),
  )
  assert_true(
    @oci_spec.is_compressed_layer_media_type(
      @oci_spec.oci_layer_zstd_media_type,
    ),
  )
  assert_true(
    @oci_spec.is_compressed_layer_media_type(
      @oci_spec.docker_layer_gzip_media_type,
    ),
  )
  assert_false(
    @oci_spec.is_compressed_layer_media_type(@oci_spec.oci_layer_media_type),
  )
}
