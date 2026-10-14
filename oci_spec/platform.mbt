///|
/// 描述内容面向的运行平台（对应 image-spec 的 `platform` 对象）。
///
/// schema 里字段全为可选，`os.version` 与 `os.features` 带点号，
/// 不能直接 derive `FromJson`，走手写解析。
pub(all) struct Platform {
  architecture : String
  os : String
  os_version : String?
  os_features : Array[String]?
  variant : String?
} derive(Eq, Debug)

///|
pub extend Platform with Eq::{equal, not_equal}

///|
pub extend Platform with @debug.Debug::{to_repr}

///|
pub impl FromJson for Platform with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let fields = object_fields(json, loc)
  {
    architecture: optional_string(fields, "architecture", loc).unwrap_or(""),
    os: optional_string(fields, "os", loc).unwrap_or(""),
    os_version: optional_string(fields, "os.version", loc),
    os_features: optional_string_array(fields, "os.features", loc),
    variant: optional_string(fields, "variant", loc),
  }
}

///|
pub extend Platform with FromJson::{from_json}

///|
pub impl ToJson for Platform with fn to_json(self) {
  let object : Map[String, Json] = Map([])
  if self.architecture != "" {
    object["architecture"] = Json(self.architecture)
  }
  if self.os != "" {
    object["os"] = Json(self.os)
  }
  optional_json_into(object, "os.version", self.os_version)
  match self.os_features {
    Some(features) => object["os.features"] = Json(features)
    None => ()
  }
  optional_json_into(object, "variant", self.variant)
  Json::object(object)
}

///|
pub extend Platform with ToJson::{to_json}

///|
pub impl Show for Platform with fn to_string(self) {
  let parts : Array[String] = []
  if self.os != "" {
    parts.push(self.os)
  }
  if self.architecture != "" {
    parts.push(self.architecture)
  }
  match self.variant {
    Some(value) if value != "" => parts.push(value)
    _ => ()
  }
  parts.join("/")
}

///|
pub extend Platform with Show::{to_string, output}

///|
/// 平台是否描述了有效的 OS/架构组合（两者之一非空即视为可用）。
pub fn Platform::is_empty(self : Platform) -> Bool {
  self.os == "" && self.architecture == ""
}

///|
/// 宽松匹配：未填写的字段视为通配符，便于「只看 os」这类查询。
pub fn Platform::matches(
  self : Platform,
  os : String,
  architecture : String,
) -> Bool {
  let os_ok = self.os == "" || self.os == os
  let arch_ok = self.architecture == "" || self.architecture == architecture
  os_ok && arch_ok
}
