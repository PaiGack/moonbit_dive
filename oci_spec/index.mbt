///|
/// 多平台镜像索引 / manifest list（对应 `application/vnd.oci.image.index.v1+json`）。
///
/// `index` 在 MoonBit 里是常用词，类型名仍取 image-spec 的 `Index`。
pub(all) struct Index {
  schema_version : Int32
  media_type : String?
  artifact_type : String?
  manifests : Array[Descriptor]
  subject : Descriptor?
  annotations : Map[String, String]?
} derive(Eq, Debug)

///|
pub extend Index with Eq::{equal, not_equal}

///|
pub extend Index with @debug.Debug::{to_repr}

///|
pub impl FromJson for Index with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let fields = object_fields(json, loc)
  {
    schema_version: required_int_field(fields, "schemaVersion", loc),
    media_type: optional_string(fields, "mediaType", loc),
    artifact_type: optional_string(fields, "artifactType", loc),
    manifests: parse_descriptor_array(fields, "manifests", loc),
    subject: parse_optional(fields, "subject", loc),
    annotations: optional_annotations(fields, loc),
  }
}

///|
pub extend Index with FromJson::{from_json}

///|
pub impl ToJson for Index with fn to_json(self) {
  let object : Map[String, Json] = {
    "schemaVersion": Json(self.schema_version),
    "manifests": Json(self.manifests),
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
pub extend Index with ToJson::{to_json}

///|
pub impl Show for Index with fn to_string(self) {
  "index schemaVersion=\{self.schema_version} manifests=\{self.manifests.length()}"
}

///|
pub extend Index with Show::{to_string, output}

///|
/// 找出指定 `os/architecture` 的 manifest descriptor。
///
/// 未填写 `platform` 的条目（如 attestation manifest）会被跳过。
pub fn Index::find_platform(
  self : Index,
  os : String,
  architecture : String,
) -> Descriptor? {
  for descriptor in self.manifests {
    match descriptor.platform {
      Some(platform) =>
        if !platform.is_empty() && platform.matches(os, architecture) {
          return Some(descriptor)
        }
      None => ()
    }
  }
  None
}

///|
/// 列出索引里所有已声明平台，去重后按 os/architecture 排序，便于 CLI 展示。
pub fn Index::platforms(self : Index) -> Array[Platform] {
  let seen : Map[String, Unit] = Map([])
  let result : Array[Platform] = []
  for descriptor in self.manifests {
    match descriptor.platform {
      Some(platform) if !platform.is_empty() => {
        let key = platform.to_string()
        if !seen.contains(key) {
          seen[key] = ()
          result.push(platform)
        }
      }
      _ => ()
    }
  }
  result.sort_by((a, b) => {
    let left = "\{a.os}\u{0}\{a.architecture}\u{0}\{a.variant.unwrap_or("")}"
    let right = "\{b.os}\u{0}\{b.architecture}\u{0}\{b.variant.unwrap_or("")}"
    left.compare(right)
  })
  result
}

///|
/// 按 media type 过滤 manifest 条目，例如只取 image manifest。
pub fn Index::manifests_with_media_type(
  self : Index,
  media_type : String,
) -> Array[Descriptor] {
  self.manifests.filter(descriptor => descriptor.media_type == media_type)
}
