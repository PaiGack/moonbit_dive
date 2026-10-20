///|
/// OCI 文档的顶层判别：一份 JSON 可能是 manifest、index 或 config。
///
/// 判别优先看 `mediaType`；缺失时按结构探测（有 `manifests` 当 index、
/// 有 `config` 当 manifest、其余当 config）。
pub(all) enum OciDocument {
  Manifest(Manifest)
  IndexDoc(Index)
  ImageConfig(ImageConfig)
} derive(Eq, Debug)

///|
pub extend OciDocument with Eq::{equal, not_equal}

///|
pub extend OciDocument with @debug.Debug::{to_repr}

///|
pub impl Show for OciDocument with fn to_string(self) {
  match self {
    Manifest(manifest) => manifest.to_string()
    IndexDoc(index) => index.to_string()
    ImageConfig(config) => config.to_string()
  }
}

///|
pub extend OciDocument with Show::{to_string, output}

///|
/// 顶层解析错误。
pub(all) suberror OciParseError {
  /// JSON 语法错误
  ParseFailed(String)
  /// 顶层不是对象
  NotAnObject(String)
  /// 字段类型不符
  InvalidField(String, String)
  /// 具体类型的解码失败，消息里带 JSON 路径
  DecodeFailed(String)
} derive(Eq, Debug)

///|
pub extend OciParseError with Eq::{equal, not_equal}

///|
pub extend OciParseError with @debug.Debug::{to_repr}

///|
pub impl Show for OciParseError with fn to_string(self) {
  match self {
    ParseFailed(message) => "invalid JSON: \{message}"
    NotAnObject(actual) => "expected a JSON object, got \{actual}"
    InvalidField(name, actual) =>
      "field \"\{name}\" has unexpected value \{actual}"
    DecodeFailed(message) => "failed to decode OCI document: \{message}"
  }
}

///|
pub extend OciParseError with Show::{to_string, output}

///|
/// 从 JSON 文本解析出 OCI 文档，自动识别 manifest / index / config。
pub fn parse_document(text : String) -> OciDocument raise OciParseError {
  let json = @json.parse(text) catch {
    error => raise ParseFailed(error.to_string())
  }
  parse_document_json(json)
}

///|
/// 同 `parse_document`，输入已经是 `Json` 值。
pub fn parse_document_json(json : Json) -> OciDocument raise OciParseError {
  let fields = match json {
    Json::Object(fields) => fields
    other => raise NotAnObject(other.stringify())
  }
  let media_type = match fields.get("mediaType") {
    Some(Json::String(value)) => Some(value)
    Some(other) => raise InvalidField("mediaType", other.stringify())
    None => None
  }
  let kind = match media_type {
    Some(media_type) => kind_of_media_type(media_type)
    None => sniff_kind(fields)
  }
  match kind {
    DocumentKind::Manifest =>
      Manifest(
        @json.from_json(json) catch {
          error => raise DecodeFailed(error.to_string())
        },
      )
    DocumentKind::IndexDoc =>
      IndexDoc(
        @json.from_json(json) catch {
          error => raise DecodeFailed(error.to_string())
        },
      )
    DocumentKind::ImageConfig =>
      ImageConfig(
        @json.from_json(json) catch {
          error => raise DecodeFailed(error.to_string())
        },
      )
  }
}

///|
/// 宽松解析镜像 config：部分工具产出的 config 没有 `schemaVersion`，
/// 这里补个默认值，只为尽力拿到 rootfs 与 history。
pub fn parse_image_config_lenient(
  text : String,
) -> ImageConfig raise OciParseError {
  let json = @json.parse(text) catch {
    error => raise ParseFailed(error.to_string())
  }
  match json {
    Json::Object(fields) => {
      let patched : Map[String, Json] = Map([])
      for key, value in fields {
        patched[key] = value
      }
      if !patched.contains("schemaVersion") {
        patched["schemaVersion"] = Json::number(2.0)
      }
      @json.from_json(Json::object(patched)) catch {
        error => raise DecodeFailed(error.to_string())
      }
    }
    other => raise NotAnObject(other.stringify())
  }
}

///|
priv enum DocumentKind {
  Manifest
  IndexDoc
  ImageConfig
}

///|
fn kind_of_media_type(media_type : String) -> DocumentKind {
  let is_index = is_index_media_type(media_type)
  let is_config = media_type == oci_config_media_type ||
    media_type == docker_config_media_type
  if is_index {
    DocumentKind::IndexDoc
  } else if is_config {
    DocumentKind::ImageConfig
  } else {
    DocumentKind::Manifest
  }
}

///|
/// 没有 `mediaType` 时按字段结构猜测。
fn sniff_kind(fields : Map[String, Json]) -> DocumentKind {
  if fields.contains("manifests") {
    DocumentKind::IndexDoc
  } else if fields.contains("config") {
    DocumentKind::Manifest
  } else {
    DocumentKind::ImageConfig
  }
}
