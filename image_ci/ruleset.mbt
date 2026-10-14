///|
/// 门禁规则集：一份可加载、可校验的规则清单。
///
/// 与 dive 的 `ci.Rules` 对应。`id` 用于报告与注解里指认是哪条规则，
/// 缺省时按出现顺序生成 `rule-1`、`rule-2`……
pub(all) struct Ruleset {
  rules : Array[Rule]
  /// 规则集的来源（文件路径 / `stdin`），出现在报告头部
  source : String
} derive(Eq, Debug)

///|
pub extend Ruleset with Eq::{equal, not_equal}

///|
pub extend Ruleset with @debug.Debug::{to_repr}

///|
pub impl Show for Ruleset with fn to_string(self) {
  "Ruleset(source=\{self.source}, rules=\{self.rules.length()})"
}

///|
pub extend Ruleset with Show::{to_string, output}

///|
/// 一条已注入 id 的规则。
pub(all) struct Rule {
  id : String
  kind : RuleKind
} derive(Eq, Debug)

///|
pub extend Rule with Eq::{equal, not_equal}

///|
pub extend Rule with @debug.Debug::{to_repr}

///|
pub impl Show for Rule with fn to_string(self) {
  "\{self.id}: \{self.kind.to_string()}"
}

///|
pub extend Rule with Show::{to_string, output}

///|
/// 规则集为空：没有可判定的规则。这是「规则非法」而不是「全过」，
/// 否则一个写错的空文件会让流水线静默放行。
pub fn Ruleset::empty(source : String) -> Ruleset {
  { rules: [], source, }
}

///|
/// 按出现顺序给每条规则补上 id。
pub fn Ruleset::of_rules(
  rules : Array[RuleKind],
  source~ : String = "<inline>",
) -> Ruleset {
  let items = []
  for index, kind in rules {
    items.push({ id: "rule-\{index + 1}", kind, })
  }
  { rules: items, source, }
}

///|
/// 规则本身有问题时抛出的错误。
///
/// 「非法」与「未通过」是两回事：这里表示配置写错了（门禁没法信这个结论），
/// 而不是镜像没达标。CLI 里两者 exit code 不同。
pub(all) suberror ConfigError {
  /// JSON 解析失败
  Parse(String)
  /// 顶层不是对象
  NotAnObject
  /// 缺少/为空的 rules 数组
  MissingRules
  /// `rules[i]` 不是对象
  RuleNotObject(Int32)
  /// `rules[i]` 的 type 字段缺失或未知
  UnknownRuleType(Int32, String)
  /// 数值字段类型不对或缺失
  BadNumber(Int32, String)
  /// 数值越界（负数、超过 i32 等）
  OutOfRange(Int32, String)
  /// score 不在 0..1
  BadEfficiency(Int32, Double)
  /// 路径模式列表为空或元素非字符串
  BadPatterns(Int32, String)
  /// maxFileSize 的目录范围写法不合法
  BadScope(Int32, String)
} derive(Eq, Debug)

///|
pub extend ConfigError with Eq::{equal, not_equal}

///|
pub extend ConfigError with @debug.Debug::{to_repr}

///|
pub impl Show for ConfigError with fn to_string(self) {
  match self {
    Parse(reason) => "cannot parse rules json: \{reason}"
    NotAnObject => "rules json must be an object"
    MissingRules => "rules json must contain a non-empty \"rules\" array"
    RuleNotObject(index) => "rules[\{index}] must be an object"
    UnknownRuleType(index, name) =>
      "rules[\{index}].type \"\{name}\" is not a known rule"
    BadNumber(index, field) => "rules[\{index}].\{field} must be an integer"
    OutOfRange(index, field) =>
      "rules[\{index}].\{field} is out of range (must be >= 0 and fit in i32)"
    BadEfficiency(index, score) =>
      "rules[\{index}].score must be within 0..1, got \{score}"
    BadPatterns(index, field) =>
      "rules[\{index}].\{field} must be a non-empty array of path patterns"
    BadScope(index, reason) => "rules[\{index}].scope is invalid: \{reason}"
  }
}

///|
pub extend ConfigError with Show::{to_string, output}

///|
/// 从 JSON 文本加载规则集。
///
/// 输入是 P4 自己定义的 DSL（见 docs/p4-rules-schema.md），与 P3 的报告 JSON
/// 不同：报告是「结果」，规则是「配置」。
pub fn Ruleset::parse(
  text : String,
  source~ : String = "<inline>",
) -> Ruleset raise ConfigError {
  let json = @json.parse(text) catch { err => raise Parse(err.to_string()) }
  Ruleset::of_json(json, source~)
}

///|
/// 从已解析的 JSON 加载规则集。
pub fn Ruleset::of_json(
  json : Json,
  source~ : String = "<inline>",
) -> Ruleset raise ConfigError {
  let object = match json {
    Json::Object(map) => map
    _ => raise NotAnObject
  }
  let raw_rules = match object.get("rules") {
    Some(Json::Array(items)) =>
      if items.is_empty() {
        raise MissingRules
      } else {
        items
      }
    Some(_) => raise MissingRules
    None => raise MissingRules
  }
  let rules = []
  for index, item in raw_rules {
    rules.push({
      id: rule_id(object, item, index),
      kind: parse_rule(item, index),
    })
  }
  { rules, source, }
}

///|
/// 单条规则的 id：顶层 `ids` 数组 > 规则自己的 `id` > 序号。
fn rule_id(top : Map[String, Json], item : Json, index : Int32) -> String {
  let fallback = "rule-\{index + 1}"
  match item {
    Json::Object(fields) =>
      match fields.get("id") {
        Some(Json::String(text)) => return text
        _ => ()
      }
    _ => ()
  }
  match top.get("ids") {
    Some(Json::Array(ids)) =>
      if index < ids.length() {
        match ids[index] {
          Json::String(text) => return text
          _ => ()
        }
      }
    _ => ()
  }
  fallback
}

///|
/// 单条规则的 kind 与合法性检查。
fn parse_rule(item : Json, index : Int32) -> RuleKind raise ConfigError {
  let fields = match item {
    Json::Object(fields) => fields
    _ => raise RuleNotObject(index)
  }
  let rule_type = match fields.get("type") {
    Some(Json::String(name)) => name
    _ => raise UnknownRuleType(index, "")
  }
  match rule_type {
    "maxImageSize" => MaxImageSize(number(fields, "maxBytes", index, 0))
    "maxLayerSize" => MaxLayerSize(number(fields, "maxBytes", index, 0))
    "maxWastedSize" => MaxWastedSize(number(fields, "maxBytes", index, 0))
    "minEfficiency" => {
      let score = match fields.get("score") {
        Some(Json::Number(value, ..)) => value
        _ => raise BadNumber(index, "score")
      }
      if score < 0.0 || score > 1.0 {
        raise BadEfficiency(index, score)
      }
      MinEfficiency(score)
    }
    "denyPaths" => DenyPaths(patterns(fields, "patterns", index))
    "allowPaths" => AllowPaths(patterns(fields, "patterns", index))
    "maxFileSize" => {
      let bytes = number(fields, "maxBytes", index, 0)
      MaxFileSize(bytes, parse_scope(fields, index))
    }
    other => raise UnknownRuleType(index, other)
  }
}

///|
/// 取一个非负整数（i32 范围内），缺省值只在字段完全没给时生效。
fn number(
  fields : Map[String, Json],
  field : String,
  index : Int32,
  default : Int32,
) -> Int32 raise ConfigError {
  match fields.get(field) {
    None => default
    Some(Json::Number(value, ..)) => {
      if value < 0.0 || value > 2147483647.0 {
        raise OutOfRange(index, field)
      }
      value.to_int()
    }
    Some(_) => raise BadNumber(index, field)
  }
}

///|
/// 取路径模式数组。两类路径规则都要求非空：空的黑名单拦不住任何东西、
/// 空的白名单会拦下全部文件，都是「以为配了其实没配」的写法。
fn patterns(
  fields : Map[String, Json],
  field : String,
  index : Int32,
) -> Array[String] raise ConfigError {
  let items = match fields.get(field) {
    Some(Json::Array(items)) =>
      if items.is_empty() {
        raise BadPatterns(index, field)
      } else {
        items
      }
    _ => raise BadPatterns(index, field)
  }
  let result = []
  for item in items {
    match item {
      Json::String(text) =>
        if text.is_empty() {
          raise BadPatterns(index, field)
        } else {
          result.push(text)
        }
      _ => raise BadPatterns(index, field)
    }
  }
  result
}

///|
/// `maxFileSize.scope`：`{"path": "/usr/**", "recursive": true}`。
///
/// `path` 是必填的，缺了就当整镜像算——这时用不带 scope 的写法更清楚，
/// 所以这里直接判非法，逼配置写明白。
fn parse_scope(
  fields : Map[String, Json],
  index : Int32,
) -> PathFilter? raise ConfigError {
  let scope = match fields.get("scope") {
    None => return None
    Some(json) => json
  }
  let scope_fields = match scope {
    Json::Object(scope_fields) => scope_fields
    _ => raise BadScope(index, "must be an object")
  }
  let raw = match scope_fields.get("path") {
    Some(Json::String(text)) =>
      if text.is_empty() {
        raise BadScope(index, "\"path\" must not be empty")
      } else {
        text
      }
    Some(_) => raise BadScope(index, "\"path\" must be a string")
    None => raise BadScope(index, "\"path\" is required")
  }
  let recursive = match scope_fields.get("recursive") {
    None => true
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) => raise BadScope(index, "\"recursive\" must be a boolean")
  }
  let pattern = PathPattern::compile(raw)
  if pattern.segments.is_empty() {
    raise BadScope(index, "\"path\" must contain at least one segment")
  }
  Some(PathFilter::new(pattern, recursive~))
}
