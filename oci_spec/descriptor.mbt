///|
/// 指向一块内容（layer/config/manifest）的引用（对应 image-spec 的 `descriptor`）。
pub(all) struct Descriptor {
  media_type : String
  digest : String
  size : Int32
  urls : Array[String]?
  annotations : Map[String, String]?
  platform : Platform?
  data : String?
} derive(Eq, Debug)

///|
pub extend Descriptor with Eq::{equal, not_equal}

///|
pub extend Descriptor with @debug.Debug::{to_repr}

///|
pub impl FromJson for Descriptor with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let fields = object_fields(json, loc)
  {
    media_type: required_string_field(fields, "mediaType", loc),
    digest: required_string_field(fields, "digest", loc),
    size: required_int_field(fields, "size", loc),
    urls: match optional_string_array(fields, "urls", loc) {
      Some(items) if items.is_empty() => None
      other => other
    },
    annotations: optional_annotations(fields, loc),
    platform: parse_optional(fields, "platform", loc),
    data: optional_string(fields, "data", loc),
  }
}

///|
pub extend Descriptor with FromJson::{from_json}

///|
pub impl ToJson for Descriptor with fn to_json(self) {
  let object : Map[String, Json] = {
    "mediaType": Json(self.media_type),
    "digest": Json(self.digest),
    "size": Json(self.size),
  }
  match self.urls {
    Some(urls) if !urls.is_empty() => object["urls"] = Json(urls)
    _ => ()
  }
  match annotations_to_json(self.annotations) {
    Some(value) => object["annotations"] = value
    None => ()
  }
  match self.platform {
    Some(platform) => object["platform"] = Json(platform)
    None => ()
  }
  match self.data {
    Some(data) => object["data"] = Json(data)
    None => ()
  }
  Json::object(object)
}

///|
pub extend Descriptor with ToJson::{to_json}

///|
pub impl Show for Descriptor with fn to_string(self) {
  "\{self.media_type} \{self.digest} (\{self.size} bytes)"
}

///|
pub extend Descriptor with Show::{to_string, output}

///|
/// 解析并校验 descriptor 的 digest，返回规范化后的 `Digest`。
pub fn Descriptor::validated_digest(
  self : Descriptor,
) -> Result[Digest, DigestError] {
  Digest::parse(self.digest)
}

///|
/// 解析必填的 descriptor 数组字段。
pub fn parse_descriptor_array(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> Array[Descriptor] raise @json.JsonDecodeError {
  match fields.get(name) {
    Some(Json::Array(items)) =>
      items.map(item => {
        @json.from_json(item) catch {
          error =>
            raise decode_error(json_loc_key(path, name), error.to_string())
        }
      })
    None | Some(Null) =>
      raise decode_error(
        json_loc_key(path, name),
        "missing required field \"\{name}\"",
      )
    Some(other) =>
      raise decode_error(
        json_loc_key(path, name),
        "expected array, got \{other.stringify()}",
      )
  }
}
