///|
/// CI 注解里用的文件名：GitHub Actions 的 `::error file=...` 需要一个路径，
/// 镜像里的路径不是仓库文件，用 `<image>` 表示「问题在镜像里，不在工作区」。
let annotation_file : String = "<image>"

///|
/// 退出码约定。
///
/// - `0`：全部规则通过
/// - `1`：有规则未通过（镜像不达标，门禁该卡住）
/// - `2`：规则本身非法（解析/校验失败），或镜像读不出来
///
/// 1 与 2 分开的意义：`1` 是「代码问题，去改 Dockerfile」，`2` 是
/// 「配置问题，去改 rules.json 或修流水线入参」，看日志的人不用猜。
pub let exit_ok : Int32 = 0

///|
pub let exit_rule_failed : Int32 = 1

///|
pub let exit_config_error : Int32 = 2

///|
/// 判定结果转 JSON，供 CI 直接消费（schema 见 docs/p4-rules-schema.md）。
pub fn CheckResult::to_json(self : CheckResult) -> Json {
  let failed = self.failed_count()
  let rules = []
  for result in self.results {
    rules.push(rule_result_to_json(result))
  }
  Json::object({
    "version": Json(1),
    "source": Json(self.source),
    "image": Json(self.image),
    "passed": Json(self.all_passed()),
    "exitCode": Json(exit_code_of(self)),
    "summary": Json::object({
      "total": Json(self.results.length()),
      "passed": Json(self.passed_count()),
      "failed": Json(failed),
    }),
    "rules": Json(rules),
  })
}

///|
pub fn CheckResult::to_json_string(self : CheckResult) -> String {
  self.to_json().stringify(indent=2)
}

///|
fn rule_result_to_json(result : RuleResult) -> Json {
  Json::object({
    "id": Json(result.id),
    "type": Json(rule_type_name(result.rule)),
    "rule": Json(result.rule.to_string()),
    "status": Json(if result.passed { "pass" } else { "fail" }),
    "observed": Json(result.observed),
    "expected": Json(result.expected),
    "reason": Json(result.reason),
    "locations": Json(result.locations.map(fn(path) { Json(path) })),
  })
}

///|
/// 规则类型名，与 rules.json 里的 `type` 字段一致，方便机器对号入座。
pub fn rule_type_name(kind : RuleKind) -> String {
  match kind {
    MaxImageSize(_) => "maxImageSize"
    MaxLayerSize(_) => "maxLayerSize"
    MaxWastedSize(_) => "maxWastedSize"
    MinEfficiency(_) => "minEfficiency"
    DenyPaths(_) => "denyPaths"
    AllowPaths(_) => "allowPaths"
    MaxFileSize(_, _) => "maxFileSize"
  }
}

///|
/// 结论对应的退出码。
pub fn exit_code_of(result : CheckResult) -> Int32 {
  if result.all_passed() {
    exit_ok
  } else {
    exit_rule_failed
  }
}

///|
/// 人类可读报告：每条规则的 pass/fail + 实测值 + 失败原因 + 汇总。
pub fn CheckResult::to_text(self : CheckResult) -> String {
  let builder = StringBuilder()
  builder.write_string("image: \{self.image}\n")
  builder.write_string("rules: \{self.source}\n")
  for result in self.results {
    builder.write_string(render_rule_line(result))
  }
  builder.write_string(
    "\{self.passed_count()}/\{self.results.length()} rules passed, \{self.failed_count()} failed\n",
  )
  if self.all_passed() {
    builder.write_string("gate: pass\n")
  } else {
    builder.write_string("gate: fail\n")
  }
  builder.to_string()
}

///|
/// 单条规则的一行结论。格式固定，可整份快照。
fn render_rule_line(result : RuleResult) -> String {
  let state = if result.passed { "pass" } else { "FAIL" }
  let line = "[\{state}] \{result.id}: \{result.rule.to_string()} (observed \{result.observed}, expected \{result.expected})\n"
  if result.passed {
    line
  } else {
    line + "        reason: \{result.reason}\n"
  }
}

///|
/// CI 注解：GitHub Actions / GitLab 都能认的 `::error` / `::notice` 形式。
///
/// 通过的规则输出 `::notice`，没通过的输出 `::error` 并把实测/期望值塞进
/// message，`title` 用规则 id，`file` 固定指向镜像本身。注解里的换行、
/// `%` 按 GitHub 的转义规则处理，否则会被 workflow 解析器截断。
pub fn CheckResult::to_annotations(self : CheckResult) -> String {
  let builder = StringBuilder()
  for result in self.results {
    let level = if result.passed { "notice" } else { "error" }
    let message = if result.passed {
      "\{result.id}: \{result.rule.to_string()} — observed \{result.observed}"
    } else {
      "\{result.id}: \{result.rule.to_string()} — \{result.reason} (observed \{result.observed}, expected \{result.expected})"
    }
    builder.write_string(
      "::\{level} file=\{annotation_file},title=\{escape_annotation(result.id)}::\{escape_annotation(message)}\n",
    )
  }
  if self.all_passed() {
    builder.write_string(
      "::notice title=image-size-gate::all \{self.results.length()} rules passed\n",
    )
  } else {
    builder.write_string(
      "::error title=image-size-gate::\{self.failed_count()}/\{self.results.length()} rules failed\n",
    )
  }
  builder.to_string()
}

///|
/// GitHub annotation 消息里的转义：`%` -> `%25`，换行 -> `%0A`，回车 -> `%0D`。
fn escape_annotation(text : String) -> String {
  let builder = StringBuilder()
  for char in text {
    match char {
      '%' => builder.write_string("%25")
      '\n' => builder.write_string("%0A")
      '\r' => builder.write_string("%0D")
      _ => builder.write_char(char)
    }
  }
  builder.to_string()
}

///|
/// 空规则数组：配置错误时没有判定结果可列。
fn empty_rules() -> Array[Json] {
  []
}

///|
/// 配置错误的机器可读输出，CI 里跟规则失败一样能解析。
pub fn config_error_to_json(error : ConfigError, source : String) -> Json {
  Json::object({
    "version": Json(1),
    "source": Json(source),
    "image": Json(""),
    "passed": Json(false),
    "exitCode": Json(exit_config_error),
    "error": Json(error.to_string()),
    "summary": Json::object({
      "total": Json(0),
      "passed": Json(0),
      "failed": Json(0),
    }),
    "rules": Json(empty_rules()),
  })
}

///|
/// 配置错误的 CI 注解。
pub fn config_error_annotation(error : ConfigError, source : String) -> String {
  "::error file=\{annotation_file},title=rules-config::\{escape_annotation("cannot load rules from \{source}: \{error.to_string()}")}\n"
}
