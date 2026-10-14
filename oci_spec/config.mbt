///|
/// 镜像的 rootfs 描述（对应 config 的 `rootfs`）。
pub(all) struct RootFS {
  /// 目前 image-spec 只定义 "layers"
  fs_type : String
  diff_ids : Array[String]
} derive(Eq, Debug)

///|
pub extend RootFS with Eq::{equal, not_equal}

///|
pub extend RootFS with @debug.Debug::{to_repr}

///|
pub impl FromJson for RootFS with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let fields = object_fields(json, loc)
  {
    fs_type: required_string_field(fields, "type", loc),
    diff_ids: match optional_field(fields, "diff_ids") {
      None => []
      Some(Json::Array(items)) =>
        items.map(item => {
          match item {
            Json::String(value) => value
            other =>
              raise decode_error(
                json_loc_key(loc, "diff_ids"),
                "expected string, got \{other.stringify()}",
              )
          }
        })
      Some(other) =>
        raise decode_error(
          json_loc_key(loc, "diff_ids"),
          "expected array of strings, got \{other.stringify()}",
        )
    },
  }
}

///|
pub extend RootFS with FromJson::{from_json}

///|
pub impl ToJson for RootFS with fn to_json(self) {
  Json::object({ "type": Json(self.fs_type), "diff_ids": Json(self.diff_ids) })
}

///|
pub extend RootFS with ToJson::{to_json}

///|
pub impl Show for RootFS with fn to_string(self) {
  "rootfs type=\{self.fs_type} diff_ids=\{self.diff_ids.length()}"
}

///|
pub extend RootFS with Show::{to_string, output}

///|
/// layer 构建历史（对应 config 的 `history` 数组元素）。
pub(all) struct History {
  created : String?
  created_by : String?
  author : String?
  comment : String?
  /// true 表示这一条不对应实际 layer（如 ENV/CMD 指令）
  empty_layer : Bool
} derive(Eq, Debug)

///|
pub extend History with Eq::{equal, not_equal}

///|
pub extend History with @debug.Debug::{to_repr}

///|
pub impl FromJson for History with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let fields = object_fields(json, loc)
  {
    created: optional_string(fields, "created", loc),
    created_by: optional_string(fields, "created_by", loc),
    author: optional_string(fields, "author", loc),
    comment: optional_string(fields, "comment", loc),
    empty_layer: match optional_field(fields, "empty_layer") {
      None => false
      Some(Json::True) => true
      Some(Json::False) => false
      Some(other) =>
        raise decode_error(
          json_loc_key(loc, "empty_layer"),
          "expected boolean, got \{other.stringify()}",
        )
    },
  }
}

///|
pub extend History with FromJson::{from_json}

///|
pub impl ToJson for History with fn to_json(self) {
  let object : Map[String, Json] = Map([])
  match self.created {
    Some(value) => object["created"] = Json(value)
    None => ()
  }
  match self.created_by {
    Some(value) => object["created_by"] = Json(value)
    None => ()
  }
  match self.author {
    Some(value) => object["author"] = Json(value)
    None => ()
  }
  match self.comment {
    Some(value) => object["comment"] = Json(value)
    None => ()
  }
  if self.empty_layer {
    object["empty_layer"] = true
  }
  Json::object(object)
}

///|
pub extend History with ToJson::{to_json}

///|
pub impl Show for History with fn to_string(self) {
  match self.created_by {
    Some(command) => command
    None => "<history entry>"
  }
}

///|
pub extend History with Show::{to_string, output}

///|
/// 容器运行时配置（config 的 `config` 字段）。
///
/// 这一坨对 OCI 是开放键值集（docker 还在往上加 Healthcheck/StopSignal 之类），
/// 全量建类型既跟不上也没收益，保留原始 JSON 交上层按需取。
pub(all) struct ContainerConfig {
  raw : Json
} derive(Eq, Debug)

///|
pub extend ContainerConfig with Eq::{equal, not_equal}

///|
pub extend ContainerConfig with @debug.Debug::{to_repr}

///|
pub impl FromJson for ContainerConfig with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  object_fields(json, loc) |> ignore
  { raw: json, }
}

///|
pub extend ContainerConfig with FromJson::{from_json}

///|
pub impl ToJson for ContainerConfig with fn to_json(self) {
  self.raw
}

///|
pub extend ContainerConfig with ToJson::{to_json}

///|
pub impl Show for ContainerConfig with fn to_string(self) {
  self.raw.stringify()
}

///|
pub extend ContainerConfig with Show::{to_string, output}

///|
/// 取顶层字段并当作字符串，缺失返回 `None`。
fn ContainerConfig::container_config_string(
  self : ContainerConfig,
  name : String,
) -> String? {
  match self.raw {
    Json::Object(fields) =>
      match fields.get(name) {
        Some(Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// 取顶层字段并当作字符串数组。
fn ContainerConfig::container_config_string_array(
  self : ContainerConfig,
  name : String,
) -> Array[String] {
  match self.raw {
    Json::Object(fields) =>
      match fields.get(name) {
        Some(Json::Array(items)) =>
          items.filter_map(item => {
            match item {
              Json::String(value) => Some(value)
              _ => None
            }
          })
        _ => []
      }
    _ => []
  }
}

///|
/// 容器的入口命令（`Entrypoint`），docker 写 `Entrypoint`，OCI 无强制约定。
pub fn ContainerConfig::entrypoint(self : ContainerConfig) -> Array[String] {
  self.container_config_string_array("Entrypoint")
}

///|
/// 容器的默认命令（`Cmd`）。
pub fn ContainerConfig::cmd(self : ContainerConfig) -> Array[String] {
  self.container_config_string_array("Cmd")
}

///|
/// 容器的工作目录（`WorkingDir`）。
pub fn ContainerConfig::working_dir(self : ContainerConfig) -> String? {
  self.container_config_string("WorkingDir")
}

///|
/// 容器的用户（`User`）。
pub fn ContainerConfig::user(self : ContainerConfig) -> String? {
  self.container_config_string("User")
}

///|
/// manifest 指向的镜像 config（对应 `application/vnd.oci.image.config.v1+json`）。
pub(all) struct ImageConfig {
  schema_version : Int32
  media_type : String?
  artifact_type : String?
  created : String?
  author : String?
  architecture : String?
  os : String?
  os_version : String?
  variant : String?
  config : ContainerConfig?
  rootfs : RootFS
  history : Array[History]
} derive(Eq, Debug)

///|
pub extend ImageConfig with Eq::{equal, not_equal}

///|
pub extend ImageConfig with @debug.Debug::{to_repr}

///|
pub impl FromJson for ImageConfig with fn from_json(json, path) {
  let loc = JsonLoc::from_json_path(path)
  let fields = object_fields(json, loc)
  {
    schema_version: required_int_field(fields, "schemaVersion", loc),
    media_type: optional_string(fields, "mediaType", loc),
    artifact_type: optional_string(fields, "artifactType", loc),
    created: optional_string(fields, "created", loc),
    author: optional_string(fields, "author", loc),
    architecture: optional_string(fields, "architecture", loc),
    os: optional_string(fields, "os", loc),
    os_version: optional_string(fields, "os.version", loc),
    variant: optional_string(fields, "variant", loc),
    config: parse_optional(fields, "config", loc),
    rootfs: parse_nested(fields, "rootfs", loc),
    history: match optional_field(fields, "history") {
      None => []
      Some(Json::Array(items)) =>
        items.map(item => {
          @json.from_json(item) catch {
            error => raise wrap_json_error(json_loc_key(loc, "history"), error)
          }
        })
      Some(other) =>
        raise decode_error(
          json_loc_key(loc, "history"),
          "expected array, got \{other.stringify()}",
        )
    },
  }
}

///|
pub extend ImageConfig with FromJson::{from_json}

///|
pub impl ToJson for ImageConfig with fn to_json(self) {
  let object : Map[String, Json] = {
    "schemaVersion": Json(self.schema_version),
    "rootfs": Json(self.rootfs),
    "history": Json(self.history),
  }
  optional_json_into(object, "mediaType", self.media_type)
  optional_json_into(object, "artifactType", self.artifact_type)
  optional_json_into(object, "created", self.created)
  optional_json_into(object, "author", self.author)
  optional_json_into(object, "architecture", self.architecture)
  optional_json_into(object, "os", self.os)
  optional_json_into(object, "os.version", self.os_version)
  optional_json_into(object, "variant", self.variant)
  match self.config {
    Some(value) => object["config"] = Json(value)
    None => ()
  }
  Json::object(object)
}

///|
pub extend ImageConfig with ToJson::{to_json}

///|
pub impl Show for ImageConfig with fn to_string(self) {
  "image config os=\{self.os.unwrap_or("")} arch=\{self.architecture.unwrap_or("")} layers=\{self.rootfs.diff_ids.length()}"
}

///|
pub extend ImageConfig with Show::{to_string, output}

///|
/// 把 config 还原成 `Platform`，方便与 index 里的平台描述比对。
pub fn ImageConfig::platform(self : ImageConfig) -> Platform {
  {
    architecture: self.architecture.unwrap_or(""),
    os: self.os.unwrap_or(""),
    os_version: self.os_version,
    os_features: None,
    variant: self.variant,
  }
}

///|
/// 真实的（非 empty_layer）history 条目，长度应当与 `rootfs.diff_ids` 一致。
pub fn ImageConfig::layer_history(self : ImageConfig) -> Array[History] {
  self.history.filter(entry => !entry.empty_layer)
}

///|
/// 合并后的 layer 描述：diff_id（未压缩摘要）与 history 一一对应。
pub(all) struct LayerHistoryEntry {
  index : Int32
  diff_id : String
  created_by : String?
} derive(Eq, Debug)

///|
pub extend LayerHistoryEntry with Eq::{equal, not_equal}

///|
pub extend LayerHistoryEntry with @debug.Debug::{to_repr}

///|
pub impl Show for LayerHistoryEntry with fn to_string(self) {
  "layer[#\{self.index}] \{self.diff_id} \{self.created_by.unwrap_or("<no command>")}"
}

///|
pub extend LayerHistoryEntry with Show::{to_string, output}

///|
/// 把 `rootfs.diff_ids` 与 history 里的非空条目对齐。
///
/// 两者长度不一致时以较短的为准——真实镜像里出现过 history 缺失的 config。
pub fn ImageConfig::layers(self : ImageConfig) -> Array[LayerHistoryEntry] {
  let commands = self.layer_history()
  let entries : Array[LayerHistoryEntry] = []
  for index, diff_id in self.rootfs.diff_ids {
    let created_by = if index < commands.length() {
      commands[index].created_by
    } else {
      None
    }
    entries.push({ index, diff_id, created_by, })
  }
  entries
}
