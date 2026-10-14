///|
/// 一条门禁规则的种类。
///
/// 每一类都对应 P3 报告里的一个可判定数字，外加两条需要看树上路径 / 文件的规则。
/// 规则本身只描述「比什么、比多少」，判定在 `check.mbt` 里做。
pub(all) enum RuleKind {
  /// 镜像当前占用上限（字节）。对齐 dive 的 `rules.maxImageSize`
  MaxImageSize(Int32)
  /// 单层写入字节上限。对齐 `rules.maxLayerSize`
  MaxLayerSize(Int32)
  /// 浪费字节上限（覆盖写入 + 被删除）。对齐 `rules.maxWastedSize`
  MaxWastedSize(Int32)
  /// efficiency score 下限，`0..1`。对齐 `rules.minEfficiency`
  MinEfficiency(Double)
  /// 路径黑名单：命中即失败（如禁止把 `node_modules` 打进镜像）
  DenyPaths(Array[String])
  /// 路径白名单：有文件落在白名单之外即失败
  AllowPaths(Array[String])
  /// 单个文件字节上限，可限定在某个目录子树内
  MaxFileSize(Int32, PathFilter?)
} derive(Eq, Debug)

///|
pub extend RuleKind with Eq::{equal, not_equal}

///|
pub extend RuleKind with @debug.Debug::{to_repr}

///|
pub impl Show for RuleKind with fn to_string(self) {
  match self {
    MaxImageSize(bytes) => "maxImageSize <= \{bytes}"
    MaxLayerSize(bytes) => "maxLayerSize <= \{bytes}"
    MaxWastedSize(bytes) => "maxWastedSize <= \{bytes}"
    MinEfficiency(score) => "minEfficiency >= \{score}"
    DenyPaths(patterns) => "denyPaths \{patterns.length()} pattern(s)"
    AllowPaths(patterns) => "allowPaths \{patterns.length()} pattern(s)"
    MaxFileSize(bytes, filter) => {
      let scope = match filter {
        Some(filter) => " under \{filter.render()}"
        None => ""
      }
      "maxFileSize <= \{bytes}\{scope}"
    }
  }
}

///|
pub extend RuleKind with Show::{to_string, output}

///|
/// 路径匹配的范围：`../` 的放大版，支持两种通配。
///
/// 支持的模式（大小写敏感）：
/// - `**` 匹配任意多段，如 `/usr/**/cache`
/// - `*` 匹配一段内的任意字符，如 `/app/*.log`
/// - 其余按字面量比较；以 `/` 结尾的模式表示「整个子树」
///
/// 匹配的是树内绝对路径（`/usr/bin/sh`），模式里的相对写法会被补上 `/`。
pub(all) struct PathPattern {
  raw : String
  segments : Array[PatternSegment]
  /// 模式以 `/` 结尾：只要落在该子树里就算命中
  subtree : Bool
} derive(Eq, Debug)

///|
pub extend PathPattern with Eq::{equal, not_equal}

///|
pub extend PathPattern with @debug.Debug::{to_repr}

///|
pub impl Show for PathPattern with fn to_string(self) {
  self.raw
}

///|
pub extend PathPattern with Show::{to_string, output}

///|
/// 模式的一段。`Any` 是 `**`，`Wildcard` 是含 `*` 的一段，`Literal` 是字面量。
pub(all) enum PatternSegment {
  Literal(String)
  Wildcard(String)
  Any
} derive(Eq, Debug)

///|
pub extend PatternSegment with Eq::{equal, not_equal}

///|
pub extend PatternSegment with @debug.Debug::{to_repr}

///|
/// 编译一条路径模式。空模式编译后永远不命中。
pub fn PathPattern::compile(raw : String) -> PathPattern {
  let normalized = if raw.has_prefix("/") { raw } else { "/" + raw }
  let subtree = normalized.length() > 1 && normalized.has_suffix("/")
  let trimmed = if subtree {
    normalized[:normalized.length() - 1].to_owned()
  } else {
    normalized
  }
  let segments = []
  for segment in trimmed.split("/") {
    let text = segment.to_owned()
    if text.is_empty() {
      continue
    }
    if text == "**" {
      segments.push(PatternSegment::Any)
    } else if text.contains("*") {
      segments.push(PatternSegment::Wildcard(text))
    } else {
      segments.push(PatternSegment::Literal(text))
    }
  }
  { raw: normalized, segments, subtree, }
}

///|
/// 路径是否命中这条模式。
///
/// 尾部的 `**` 可以匹配零段，所以 `/usr/lib/**` 本身就命中 `/usr/lib`；
/// 以 `/` 结尾的写法（`/var/log/`）等价于在末尾补一个 `**`。
pub fn PathPattern::matches(self : PathPattern, path : String) -> Bool {
  if self.segments.is_empty() {
    return false
  }
  let parts = []
  for segment in path.split("/") {
    let text = segment.to_owned()
    if !text.is_empty() {
      parts.push(text)
    }
  }
  if match_segments(self.segments, 0, parts, 0, prefix=self.subtree) {
    return true
  }
  // 以目录结尾写法的兜底：`/var/log` 也要能命中 `/var/log` 自身
  self.subtree &&
  parts.length() == self.segments.length() &&
  match_segments(self.segments, 0, parts, 0, prefix=true)
}

///|
/// 递归匹配：`**` 可以吃掉任意多段。
///
/// 递归匹配：`**` 可以吃掉任意多段；`prefix` 为真时允许路径比模式更深
/// （以 `/` 结尾的子树写法用它）。
fn match_segments(
  patterns : Array[PatternSegment],
  pattern_index : Int32,
  parts : Array[String],
  part_index : Int32,
  prefix~ : Bool,
) -> Bool {
  if pattern_index >= patterns.length() {
    return prefix || part_index >= parts.length()
  }
  match patterns[pattern_index] {
    PatternSegment::Any => {
      let mut index = part_index
      while index <= parts.length() {
        if match_segments(patterns, pattern_index + 1, parts, index, prefix~) {
          return true
        }
        index = index + 1
      }
      false
    }
    PatternSegment::Literal(text) =>
      part_index < parts.length() &&
      parts[part_index] == text &&
      match_segments(
        patterns,
        pattern_index + 1,
        parts,
        part_index + 1,
        prefix~,
      )
    PatternSegment::Wildcard(pattern) =>
      part_index < parts.length() &&
      wildcard_match(pattern, parts[part_index]) &&
      match_segments(
        patterns,
        pattern_index + 1,
        parts,
        part_index + 1,
        prefix~,
      )
  }
}

///|
/// 单段通配：`*` 匹配任意字符序列，其余按字节比较。
fn wildcard_match(pattern : String, text : String) -> Bool {
  let mut pattern_index = 0
  let mut text_index = 0
  let mut star = -1
  let mut backtrack = 0
  while text_index < text.length() {
    if pattern_index < pattern.length() &&
      pattern.code_unit_at(pattern_index) == text.code_unit_at(text_index) {
      pattern_index = pattern_index + 1
      text_index = text_index + 1
    } else if pattern_index < pattern.length() &&
      pattern.code_unit_at(pattern_index) == 42 { // '*'
      star = pattern_index
      backtrack = text_index
      pattern_index = pattern_index + 1
    } else if star >= 0 {
      pattern_index = star + 1
      backtrack = backtrack + 1
      text_index = backtrack
    } else {
      return false
    }
  }
  while pattern_index < pattern.length() &&
        pattern.code_unit_at(pattern_index) == 42 {
    pattern_index = pattern_index + 1
  }
  pattern_index >= pattern.length()
}

///|
/// 单文件上限的限定范围：`path` 模式 + 递归/仅直接子项。
pub(all) struct PathFilter {
  pattern : PathPattern
  /// 是否连子孙目录里的文件一起算
  recursive : Bool
} derive(Eq, Debug)

///|
pub extend PathFilter with Eq::{equal, not_equal}

///|
pub extend PathFilter with @debug.Debug::{to_repr}

///|
pub impl Show for PathFilter with fn to_string(self) {
  self.render()
}

///|
pub extend PathFilter with Show::{to_string, output}

///|
pub fn PathFilter::new(
  pattern : PathPattern,
  recursive~ : Bool = true,
) -> PathFilter {
  { pattern, recursive, }
}

///|
/// 过滤器的人话形式，出现在失败原因里。
pub fn PathFilter::render(self : PathFilter) -> String {
  let scope = if self.recursive {
    " (recursive)"
  } else {
    " (direct children only)"
  }
  self.pattern.raw + scope
}

///|
/// 文件是否是过滤器管得着的。
pub fn PathFilter::covers(self : PathFilter, path : String) -> Bool {
  if self.recursive {
    self.pattern.matches(path)
  } else {
    self.pattern.matches(path) && !path_matches_deeper(self.pattern, path)
  }
}

///|
/// 路径在模式之外还多出段数：说明它是子孙，非递归时不算。
fn path_matches_deeper(pattern : PathPattern, path : String) -> Bool {
  let parts = []
  for segment in path.split("/") {
    let text = segment.to_owned()
    if !text.is_empty() {
      parts.push(text)
    }
  }
  parts.length() > pattern.segments.length()
}
