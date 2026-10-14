///|
/// 一次判定：一条规则 + 一个镜像 + 一个结论。
pub(all) struct RuleResult {
  id : String
  /// 规则原文，出现在报告与注解里
  rule : RuleKind
  /// 是否通过
  passed : Bool
  /// 实际量到的值（人话形式，如 `12 bytes` / `23.1%` / `3 path(s)`）
  observed : String
  /// 规则要求的阈值（人话形式）
  expected : String
  /// 没通过时给出的理由，通过时为空
  reason : String
  /// 指认现场用的路径（最多若干条），可被 CI 注解引用
  locations : Array[String]
} derive(Eq, Debug)

///|
pub extend RuleResult with Eq::{equal, not_equal}

///|
pub extend RuleResult with @debug.Debug::{to_repr}

///|
pub impl Show for RuleResult with fn to_string(self) {
  let state = if self.passed { "pass" } else { "fail" }
  "[\{state}] \{self.id}: \{self.rule.to_string()} (observed \{self.observed})"
}

///|
pub extend RuleResult with Show::{to_string, output}

///|
/// 整份规则集的判定结果。
pub(all) struct CheckResult {
  results : Array[RuleResult]
  /// 规则来源，报告头部用
  source : String
  /// 被检查的镜像（文件路径或 `stdin`）
  image : String
} derive(Eq, Debug)

///|
pub extend CheckResult with Eq::{equal, not_equal}

///|
pub extend CheckResult with @debug.Debug::{to_repr}

///|
pub impl Show for CheckResult with fn to_string(self) {
  "CheckResult(\{self.passed_count()}/\{self.results.length()} passed)"
}

///|
pub extend CheckResult with Show::{to_string, output}

///|
/// 通过的规则条数。
pub fn CheckResult::passed_count(self : CheckResult) -> Int32 {
  let mut count = 0
  for result in self.results {
    if result.passed {
      count = count + 1
    }
  }
  count
}

///|
/// 没通过的规则条数。
pub fn CheckResult::failed_count(self : CheckResult) -> Int32 {
  self.results.length() - self.passed_count()
}

///|
/// 全部通过（规则集非空时才有意义；空规则集走 `ConfigError`）。
pub fn CheckResult::all_passed(self : CheckResult) -> Bool {
  self.failed_count() == 0
}

///|
/// 运行整份规则集。
///
/// `report` 提供体积口径的数字，`tree` 提供路径级的现场（白/黑名单、单文件上限）。
/// 两者必须来自同一张镜像，否则判定的是两件事。
pub fn Ruleset::check(
  self : Ruleset,
  report : @dive_analysis.Report,
  tree : @layer_tree.FileTree,
  image~ : String = "<inline>",
) -> CheckResult {
  let files = @dive_analysis.file_sizes(tree)
  let results = []
  for rule in self.rules {
    results.push(check_rule(rule, report, tree, files))
  }
  { results, source: self.source, image, }
}

///|
/// 逐条判定。六类规则的实现都在这里，每类对应一段 `match` 分支。
fn check_rule(
  rule : Rule,
  report : @dive_analysis.Report,
  tree : @layer_tree.FileTree,
  files : Map[String, Int32],
) -> RuleResult {
  match rule.kind {
    MaxImageSize(limit) => {
      let observed = report.final_file_bytes
      measured(rule, observed, limit, "\{observed} bytes", "<= \{limit} bytes")
    }
    MaxLayerSize(limit) => {
      // 取单层最大值：任何一层超限都算失败，并指认是第几层
      let mut worst = 0
      let mut worst_layer = -1
      for usage in report.usages {
        if usage.written_bytes > worst {
          worst = usage.written_bytes
          worst_layer = usage.layer
        }
      }
      if worst <= limit {
        passed_result(rule, "\{worst} bytes", "<= \{limit} bytes per layer", [
          "L\{worst_layer}",
        ])
      } else {
        failed_result(
          rule,
          "\{worst} bytes",
          "<= \{limit} bytes per layer",
          "layer L\{worst_layer} wrote \{worst} bytes, over the \{limit} bytes limit",
          ["L\{worst_layer}"],
        )
      }
    }
    MaxWastedSize(limit) => {
      let observed = report.overwritten_wasted + report.deleted_wasted
      measured(rule, observed, limit, "\{observed} bytes", "<= \{limit} bytes")
    }
    MinEfficiency(limit) => {
      let score = report.efficiency.score()
      // 允许一个极小的浮点误差：配置里写 0.5、报告算出来 0.5000000001 不该判失败
      let epsilon = 0.0000001
      if score + epsilon >= limit {
        passed_result(rule, percent1(score), ">= \{percent1(limit)}", [])
      } else {
        failed_result(
          rule,
          percent1(score),
          ">= \{percent1(limit)}",
          "efficiency \{percent1(score)} is below the \{percent1(limit)} floor; \{report.overwritten_wasted + report.deleted_wasted} bytes were wasted across layers",
          [],
        )
      }
    }
    DenyPaths(patterns) => check_paths(rule, patterns, tree, deny=true)
    AllowPaths(patterns) => check_paths(rule, patterns, tree, deny=false)
    MaxFileSize(limit, filter) => check_file_size(rule, limit, filter, files)
  }
}

///|
/// 构造一个「通过」的结论。
fn passed_result(
  rule : Rule,
  observed : String,
  expected : String,
  locations : Array[String],
) -> RuleResult {
  {
    id: rule.id,
    rule: rule.kind,
    passed: true,
    observed,
    expected,
    reason: "",
    locations,
  }
}

///|
/// 构造一个「没通过」的结论。
fn failed_result(
  rule : Rule,
  observed : String,
  expected : String,
  reason : String,
  locations : Array[String],
) -> RuleResult {
  {
    id: rule.id,
    rule: rule.kind,
    passed: false,
    observed,
    expected,
    reason,
    locations,
  }
}

///|
/// 「不超过上限」类规则的统一判定（大小、浪费）。
fn measured(
  rule : Rule,
  observed : Int32,
  limit : Int32,
  observed_text : String,
  expected_text : String,
) -> RuleResult {
  if observed <= limit {
    passed_result(rule, observed_text, expected_text, [])
  } else {
    failed_result(
      rule,
      observed_text,
      expected_text,
      "observed \{observed} bytes exceeds the \{limit} bytes limit by \{observed - limit} bytes",
      [],
    )
  }
}

///|
/// 路径黑/白名单判定。
///
/// 目录不算「命中」：目录节点会把整个子树拖下水，报出来的现场也不是用户想看的。
/// 命中列表按路径序排列，上限 `max_locations`，避免注解刷屏。
let max_locations : Int32 = 10

///|
fn check_paths(
  rule : Rule,
  raw_patterns : Array[String],
  tree : @layer_tree.FileTree,
  deny~ : Bool,
) -> RuleResult {
  let patterns = raw_patterns.map(PathPattern::compile)
  let hits = []
  let mut scanned = 0
  for path in tree.paths() {
    let node = match tree.get(path) {
      Some(node) => node
      None => continue
    }
    if node.is_dir() {
      continue
    }
    scanned = scanned + 1
    for pattern in patterns {
      if pattern.matches(path) {
        hits.push(path)
        break
      }
    }
  }
  let expected = if deny {
    "no file matches \{render_patterns(raw_patterns)}"
  } else {
    "every file matches \{render_patterns(raw_patterns)}"
  }
  let observed = if deny {
    "\{hits.length()} matching file(s)"
  } else {
    "\{scanned - hits.length()} file(s) outside the whitelist"
  }
  if deny {
    if hits.is_empty() {
      passed_result(rule, observed, expected, [])
    } else {
      failed_result(
        rule,
        observed,
        expected,
        "forbidden paths present: \{render_locations(hits)}",
        truncate(hits),
      )
    }
  } else {
    // 白名单：反向收集「不在名单里」的路径
    let outside = []
    for path in tree.paths() {
      let node = match tree.get(path) {
        Some(node) => node
        None => continue
      }
      if node.is_dir() {
        continue
      }
      let mut covered = false
      for pattern in patterns {
        if pattern.matches(path) {
          covered = true
          break
        }
      }
      if !covered {
        outside.push(path)
      }
    }
    if outside.is_empty() {
      passed_result(rule, observed, expected, [])
    } else {
      failed_result(
        rule,
        observed,
        expected,
        "\{outside.length()} path(s) outside the whitelist: \{render_locations(outside)}",
        truncate(outside),
      )
    }
  }
}

///|
/// 单文件上限判定，可限定在某个目录子树内。
fn check_file_size(
  rule : Rule,
  limit : Int32,
  filter : PathFilter?,
  files : Map[String, Int32],
) -> RuleResult {
  let scope_text = match filter {
    Some(filter) => " under \{filter.render()}"
    None => ""
  }
  let oversized = []
  for path, size in files {
    let covered = match filter {
      Some(filter) => filter.covers(path)
      None => true
    }
    if covered && size > limit {
      oversized.push((path, size))
    }
  }
  oversized.sort_by(fn(left, right) {
    if left.1 != right.1 {
      // 大文件在前：失败原因里先看最值得削的那个
      right.1 - left.1
    } else {
      @layer_tree.path_order(left.0, right.0)
    }
  })
  let observed = if oversized.is_empty() {
    "largest \{largest_size(files, filter)} bytes"
  } else {
    "\{oversized.length()} file(s) over the limit"
  }
  let expected = "<= \{limit} bytes per file\{scope_text}"
  if oversized.is_empty() {
    passed_result(rule, observed, expected, [])
  } else {
    let worst = oversized[0]
    failed_result(
      rule,
      observed,
      expected,
      "\{oversized.length()} file(s) exceed \{limit} bytes, largest is \{worst.0} (\{worst.1} bytes)",
      oversized.map(fn(item) { item.0 }),
    )
  }
}

///|
/// 范围内最大的文件；范围内没有文件时返回 0。
fn largest_size(files : Map[String, Int32], filter : PathFilter?) -> Int32 {
  let mut largest = 0
  for path, size in files {
    let covered = match filter {
      Some(filter) => filter.covers(path)
      None => true
    }
    if covered && size > largest {
      largest = size
    }
  }
  largest
}

///|
/// 模式列表的人话形式：`/a/**`, `/b/*.log`。
fn render_patterns(patterns : Array[String]) -> String {
  "(" + patterns.join(", ") + ")"
}

///|
/// 现场路径的人话形式，最多几条，其余用 `+N more` 收尾。
fn render_locations(paths : Array[String]) -> String {
  let shown = truncate(paths)
  let extra = paths.length() - shown.length()
  let text = shown.join(", ")
  if extra > 0 {
    "\{text} +\{extra} more"
  } else {
    text
  }
}

///|
/// 截断到 `max_locations` 条。
fn truncate(paths : Array[String]) -> Array[String] {
  if paths.length() > max_locations {
    paths[:max_locations].to_owned()
  } else {
    paths
  }
}

///|
/// 分数的人话形式：保留一位小数的百分比，报告与注解共用。
pub fn percent1(score : Double) -> String {
  let scaled = (score * 1000.0).round() / 10.0
  "\{scaled}%"
}
