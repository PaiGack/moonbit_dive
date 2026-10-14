///|
/// 解析过程中的字段位置，形如 `/layers/0/digest` 的 JSON Pointer。
///
/// 不用 `@json.JsonPath` 是因为它对外不可构造：本包手写解析、自行拼路径。
pub(all) struct JsonLoc {
  path : String
} derive(Eq, Debug)

///|
pub extend JsonLoc with Eq::{equal, not_equal}

///|
pub extend JsonLoc with @debug.Debug::{to_repr}

///|
pub impl Show for JsonLoc with fn to_string(self) {
  if self.path == "" {
    "/"
  } else {
    self.path
  }
}

///|
pub extend JsonLoc with Show::{to_string, output}

///|
/// 根位置。
pub fn JsonLoc::root() -> JsonLoc {
  { path: "", }
}

///|
/// 把 JSON 库的位置折叠成本包的位置。
pub fn JsonLoc::from_json_path(path : @json.JsonPath) -> JsonLoc {
  { path: path.to_string(), }
}

///|
/// 追加对象键。
pub fn json_loc_key(loc : JsonLoc, key : String) -> JsonLoc {
  { path: "\{loc.path}/\{key}", }
}

///|
/// 追加数组下标。
pub fn json_loc_index(loc : JsonLoc, index : Int32) -> JsonLoc {
  { path: "\{loc.path}/\{index}", }
}

///|
/// 拼接位置与错误消息，抛出 `@json.JsonDecodeError`。
///
/// `@json.JsonPath` 没有公开构造器，位置信息直接写进消息文本。
fn decode_error(loc : JsonLoc, message : String) -> @json.JsonDecodeError {
  @json.JsonDecodeError((empty_json_path, "\{loc}: \{message}"))
}

///|
/// 一个空路径常量。
///
/// `@json.JsonPath` 没有公开构造器，唯一的来源是一次失败的解码，
/// 所以启动时借一次：解析 `"x"` 当 `Int` 必然失败，把错误里的根路径留下来。
/// 之后所有本包自己抛的 `JsonDecodeError` 都用它——路径信息已经在消息文本里。
let empty_json_path : @json.JsonPath = json_root_path()

///|
fn json_root_path() -> @json.JsonPath {
  let _ : Int32 = @json.from_json(("x" : Json)) catch {
    JsonDecodeError((path, _)) => return path
  }
  abort("json_root_path: unreachable")
}

///|
/// 把底层 JSON 库的错误转成本包的错误并补上位置。
fn wrap_json_error(
  loc : JsonLoc,
  error : @json.JsonDecodeError,
) -> @json.JsonDecodeError {
  let message = match error {
    JsonDecodeError((_, message)) => message
  }
  decode_error(loc, message)
}

///|
/// 把 JSON 值当作对象取字段表，非对象时报错。
///
/// 本包统一用它做「未知字段容忍 + 缺失字段报错」的手写解析：
/// 取出 `Map` 后按需读取，天然忽略 schema 演进新增的字段。
pub fn object_fields(
  json : Json,
  path : JsonLoc,
) -> Map[String, Json] raise @json.JsonDecodeError {
  match json {
    Json::Object(fields) => fields
    other =>
      raise decode_error(path, "expected object, got \{other.stringify()}")
  }
}

///|
/// 取必填字符串字段，缺失或类型不符都报错。
pub fn required_string_field(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> String raise @json.JsonDecodeError {
  match fields.get(name) {
    Some(Json::String(value)) => value
    None | Some(Null) =>
      raise decode_error(
        json_loc_key(path, name),
        "missing required field \"\{name}\"",
      )
    Some(other) =>
      raise decode_error(
        json_loc_key(path, name),
        "expected string, got \{other.stringify()}",
      )
  }
}

///|
/// 取必填整型字段（JSON number 且无小数部分），缺失或类型不符都报错。
pub fn required_int_field(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> Int32 raise @json.JsonDecodeError {
  match fields.get(name) {
    Some(Json::Number(value, ..)) =>
      if value == value.floor() {
        value.to_int()
      } else {
        raise decode_error(
          json_loc_key(path, name),
          "expected integer, got \{value}",
        )
      }
    None | Some(Null) =>
      raise decode_error(
        json_loc_key(path, name),
        "missing required field \"\{name}\"",
      )
    Some(other) =>
      raise decode_error(
        json_loc_key(path, name),
        "expected integer, got \{other.stringify()}",
      )
  }
}

///|
/// 取必填对象字段并返回其字段表。
pub fn required_object_field(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> Map[String, Json] raise @json.JsonDecodeError {
  match fields.get(name) {
    Some(Json::Object(inner)) => inner
    None | Some(Null) =>
      raise decode_error(
        json_loc_key(path, name),
        "missing required field \"\{name}\"",
      )
    Some(other) =>
      raise decode_error(
        json_loc_key(path, name),
        "expected object, got \{other.stringify()}",
      )
  }
}

///|
/// 取必填对象字段并包成 `Json`，方便交给 `@json.from_json`。
pub fn required_object_json_field(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> Json raise @json.JsonDecodeError {
  Json::object(required_object_field(fields, name, path))
}

///|
/// 取选填字段，缺失或 null 返回 `None`。
pub fn optional_field(fields : Map[String, Json], name : String) -> Json? {
  match fields.get(name) {
    None | Some(Null) => None
    Some(value) => Some(value)
  }
}

///|
/// 取选填字符串字段；类型不符报错，缺失返回 `None`。
pub fn optional_string(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> String? raise @json.JsonDecodeError {
  match optional_field(fields, name) {
    None => None
    Some(Json::String(value)) => Some(value)
    Some(other) =>
      raise decode_error(
        json_loc_key(path, name),
        "expected string, got \{other.stringify()}",
      )
  }
}

///|
/// 取选填的字符串数组字段。
pub fn optional_string_array(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> Array[String]? raise @json.JsonDecodeError {
  match optional_field(fields, name) {
    None => None
    Some(Json::Array(items)) =>
      Some(
        items.map(item => {
          match item {
            Json::String(value) => value
            other =>
              raise decode_error(
                json_loc_key(path, name),
                "expected array of strings, got \{other.stringify()}",
              )
          }
        }),
      )
    Some(other) =>
      raise decode_error(
        json_loc_key(path, name),
        "expected array of strings, got \{other.stringify()}",
      )
  }
}

///|
/// 取选填 `annotations`（`Map[String, String]`）。
pub fn optional_annotations(
  fields : Map[String, Json],
  path : JsonLoc,
) -> Map[String, String]? raise @json.JsonDecodeError {
  match optional_field(fields, "annotations") {
    None => None
    Some(Json::Object(entries)) => {
      let annotations : Map[String, String] = Map([])
      for key, value in entries {
        match value {
          Json::String(text) => annotations[key] = text
          other =>
            raise decode_error(
              json_loc_key(json_loc_key(path, "annotations"), key),
              "expected string annotation value, got \{other.stringify()}",
            )
        }
      }
      Some(annotations)
    }
    Some(other) =>
      raise decode_error(
        json_loc_key(path, "annotations"),
        "expected object, got \{other.stringify()}",
      )
  }
}

///|
/// 序列化 `annotations`，`None` 与空表都不输出。
pub fn annotations_to_json(annotations : Map[String, String]?) -> Json? {
  match annotations {
    None => None
    Some(map) =>
      if map.is_empty() {
        None
      } else {
        let object : Map[String, Json] = Map([])
        for key, value in map {
          object[key] = Json(value)
        }
        Some(Json::object(object))
      }
  }
}

///|
/// 解析可选的嵌套对象字段，缺失返回 `None`。
pub fn[T : FromJson] parse_optional(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> T? raise @json.JsonDecodeError {
  match optional_field(fields, name) {
    None => None
    Some(value) =>
      Some(
        @json.from_json(value) catch {
          error => raise wrap_json_error(json_loc_key(path, name), error)
        },
      )
  }
}

///|
/// 解析必填的嵌套对象字段，错误位置补上字段名。
pub fn[T : FromJson] parse_nested(
  fields : Map[String, Json],
  name : String,
  path : JsonLoc,
) -> T raise @json.JsonDecodeError {
  let json = required_object_json_field(fields, name, path)
  @json.from_json(json) catch {
    error => raise wrap_json_error(json_loc_key(path, name), error)
  }
}

///|
/// 把 `Option[String]` 以 JSON 字符串写入对象，`None` 不写。
pub fn optional_json_into(
  object : Map[String, Json],
  name : String,
  value : String?,
) -> Unit {
  match value {
    Some(text) => object[name] = Json(text)
    None => ()
  }
}
