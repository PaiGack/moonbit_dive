///|
/// OCI image-spec media types.
///
/// Reference: <https://github.com/opencontainers/image-spec/blob/main/media-types.md>
pub let oci_manifest_media_type : String = "application/vnd.oci.image.manifest.v1+json"

///|
pub let oci_index_media_type : String = "application/vnd.oci.image.index.v1+json"

///|
pub let oci_config_media_type : String = "application/vnd.oci.image.config.v1+json"

///|
pub let oci_descriptor_media_type : String = "application/vnd.oci.descriptor.v1+json"

///|
pub let oci_layout_media_type : String = "application/vnd.oci.layout.header.v1+json"

///|
pub let oci_layer_media_type : String = "application/vnd.oci.image.layer.v1.tar"

///|
pub let oci_layer_gzip_media_type : String = "application/vnd.oci.image.layer.v1.tar+gzip"

///|
pub let oci_layer_zstd_media_type : String = "application/vnd.oci.image.layer.v1.tar+zstd"

///|
/// Docker 兼容的 media type（OCI 之前的镜像普遍使用）。
pub let docker_manifest_media_type : String = "application/vnd.docker.distribution.manifest.v2+json"

///|
pub let docker_manifest_list_media_type : String = "application/vnd.docker.distribution.manifest.list.v2+json"

///|
pub let docker_config_media_type : String = "application/vnd.docker.container.image.v1+json"

///|
pub let docker_layer_gzip_media_type : String = "application/vnd.docker.image.rootfs.diff.tar.gzip"

///|
pub let docker_layer_media_type : String = "application/vnd.docker.image.rootfs.diff.tar"

///|
pub let docker_foreign_layer_gzip_media_type : String = "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip"

///|
/// 判断 media type 是否是本包已知的 manifest 类型（OCI 或 docker）。
pub fn is_manifest_media_type(media_type : String) -> Bool {
  media_type == oci_manifest_media_type ||
  media_type == docker_manifest_media_type
}

///|
/// 判断 media type 是否是本包已知的 index / manifest list 类型（OCI 或 docker）。
pub fn is_index_media_type(media_type : String) -> Bool {
  media_type == oci_index_media_type ||
  media_type == docker_manifest_list_media_type
}

///|
/// 判断 media type 是否是 layer 类型（OCI 或 docker，含 gzip/zstd 压缩）。
pub fn is_layer_media_type(media_type : String) -> Bool {
  let oci_layer = media_type.has_prefix("application/vnd.oci.image.layer.")
  let docker_layer = media_type.has_prefix(
    "application/vnd.docker.image.rootfs",
  )
  oci_layer || docker_layer
}

///|
/// 判断 layer media type 是否已压缩。
pub fn is_compressed_layer_media_type(media_type : String) -> Bool {
  media_type.has_suffix("+gzip") ||
  media_type.has_suffix("+zstd") ||
  media_type.has_suffix(".gzip")
}
