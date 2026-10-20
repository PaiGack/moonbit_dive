///|
/// 镜像 manifest（对应 `application/vnd.oci.image.manifest.v1+json`）。
pub(all) struct Manifest {
  schema_version : Int32
  media_type : String?
  artifact_type : String?
  config : Descriptor
  layers : Array[Descriptor]
  subject : Descriptor?
  annotations : Map[String, String]?
} derive(Eq, Debug)

///|
pub extend Manifest with Eq::{equal, not_equal}

///|
pub extend Manifest with @debug.Debug::{to_repr}

///|
pub impl FromJson for Manifest with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let fields = object_fields(json, loc)
  {
    schema_version: required_int_field(fields, "schemaVersion", loc),
    media_type: optional_string(fields, "mediaType", loc),
    artifact_type: optional_string(fields, "artifactType", loc),
    config: parse_nested(fields, "config", loc),
    layers: parse_descriptor_array(fields, "layers", loc),
    subject: parse_optional(fields, "subject", loc),
    annotations: optional_annotations(fields, loc),
  }
}

///|
pub extend Manifest with FromJson::{from_json}

///|
pub impl ToJson for Manifest with fn to_json(self) {
  let object : Map[String, Json] = {
    "schemaVersion": Json(self.schema_version),
    "config": Json(self.config),
    "layers": Json(self.layers),
  }
  optional_json_into(object, "mediaType", self.media_type)
  optional_json_into(object, "artifactType", self.artifact_type)
  match self.subject {
    Some(subject) => object["subject"] = Json(subject)
    None => ()
  }
  match annotations_to_json(self.annotations) {
    Some(value) => object["annotations"] = value
    None => ()
  }
  Json::object(object)
}

///|
pub extend Manifest with ToJson::{to_json}

///|
pub impl Show for Manifest with fn to_string(self) {
  "manifest schemaVersion=\{self.schema_version} config=\{self.config.digest} layers=\{self.layers.length()}"
}

///|
pub extend Manifest with Show::{to_string, output}

///|
/// manifest 是否指向一个 OCI index（manifest list）而非单平台镜像。
pub fn Manifest::is_index(self : Manifest) -> Bool {
  match self.media_type {
    Some(media_type) => is_index_media_type(media_type)
    None => false
  }
}

///|
/// 所有 layer descriptor 的 size 求和，即 layer 压缩后总字节数。
///
/// 解压后大小要看 config 的 rootfs，不在这一层。
pub fn Manifest::total_layer_size(self : Manifest) -> Int32 {
  self.layers.fold(init=0, fn(acc, layer) { acc + layer.size })
}

///|
/// 按 media type 过滤 layer，便于区分 gzip / zstd / 未压缩层。
pub fn Manifest::layers_with_media_type(
  self : Manifest,
  media_type : String,
) -> Array[Descriptor] {
  self.layers.filter(layer => layer.media_type == media_type)
}

///|
/// 按 config 的 digest 打开 config：调用方拿到的是「manifest 说 config 长啥样」，
/// 真正的 config 内容由 P2/P3 从 registry 或本地镜像里取。
pub fn Manifest::config_digest(self : Manifest) -> Digest raise DigestError {
  Digest::parse(self.config.digest)
}
