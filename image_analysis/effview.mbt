///|
/// `--efficiency` 视图的 JSON 结构版本号。
///
/// 与 `json_report_schema_version` 分开：那是整份体积报告的结构，
/// 这是「逐路径效率表」这一种视图的结构，两边各自演进互不牵连。
pub let efficiency_view_schema_version : Int32 = 1

///|
/// 一条路径的「多写了几份」：`cumulative - min`。
///
/// 口径与 efficiency score 完全一致（dive 的 `cumulative / min_discovered`），
/// 与 `PathSize::wasted_bytes`（被覆盖 + 被删的实际字节）**不是同一个数**，
/// 别把两个榜的数字混着看：
///
/// - 同一路径写两次、大小相同 → 这里 `size` 为正（空间被占了 2 份），`wasted_bytes` 为 0
/// - 写一次 100 字节再 whiteout 删掉 → 这里 `size = 100`（min 取 0），`wasted_bytes` 也是 100
/// - 先写 10 再写 1 → 这里 `size = 1`（多写的那一份只有 1 字节），`wasted_bytes` 是 10
pub(all) struct PathEfficiencyRow {
  path : String
  /// 写了几版
  versions : Int32
  /// 所有版本的字节数之和
  cumulative_bytes : Int32
  /// 所有版本里最小的那个字节数
  min_bytes : Int32
  /// 多写了几份：`cumulative - min`，即这张表的排序键
  size : Int32
} derive(Eq, Debug)

///|
pub extend PathEfficiencyRow with Eq::{equal, not_equal}

///|
pub extend PathEfficiencyRow with @debug.Debug::{to_repr}

///|
pub impl Show for PathEfficiencyRow with fn to_string(self) {
  "\{self.path}: cumulative \{self.cumulative_bytes}, min \{self.min_bytes}, size \{self.size}, versions \{self.versions}"
}

///|
pub extend PathEfficiencyRow with Show::{to_string, output}

///|
/// 逐路径效率表的渲染参数。`top` 传负数表示不截断（CLI 里用 `--top 0` 表达）。
pub(all) struct EfficiencyViewOptions {
  /// 只看这个前缀下的路径；`None` 表示整棵树
  path : String?
  /// 最多几条，负数不截断
  top : Int32
} derive(Eq, @debug.Debug)

///|
pub extend EfficiencyViewOptions with Eq::{equal, not_equal}

///|
pub extend EfficiencyViewOptions with @debug.Debug::{to_repr}

///|
pub fn EfficiencyViewOptions::new(
  path~ : String? = None,
  top~ : Int32 = 10,
) -> EfficiencyViewOptions {
  { path, top, }
}

///|
/// 从效率报表里挑出要展示的行。
///
/// 数据只从 `EfficiencyReport.paths` 取，**不重算**：这张表的数字必须能推出
/// efficiency 总分，另起一套口径迟早会对不上。
///
/// 排序沿用 `paths` 的顺序（`efficiency_of_versions` 已按 `cumulative - min` 降序、
/// 同分按 `layer_tree.path_order` 稳定排序）。截断在过滤之后做——
/// 「只看 /app 下的前 20 条」是用户的意图，先截断再过滤会少出一半。
pub fn efficiency_view_rows(
  report : EfficiencyReport,
  options : EfficiencyViewOptions,
) -> Array[PathEfficiencyRow] {
  let rows = []
  for entry in report.paths {
    if !under_prefix(entry.path, options.path) {
      continue
    }
    rows.push({
      path: entry.path,
      versions: entry.versions,
      cumulative_bytes: entry.cumulative_bytes,
      min_bytes: entry.min_bytes,
      size: entry.cumulative_bytes - entry.min_bytes,
    })
  }
  if options.top >= 0 && rows.length() > options.top {
    rows[:options.top].to_owned()
  } else {
    rows
  }
}

///|
/// 前缀过滤：先规范化，再看是否落在子树内。
///
/// `/app/` 与 `/app` 等价——用户抄路径时带不带尾斜杠不该影响结果。
fn under_prefix(path : String, prefix : String?) -> Bool {
  match prefix {
    None => true
    Some(raw) => {
      // 输入是用户手写的路径，可能带 `./` 或重复斜杠，先规范化再比
      let normalized = match @layer_tree.normalize_path(raw) {
        Ok(path) => path
        Err(_) => "/"
      }
      @layer_tree.path_is_under(path, normalized)
    }
  }
}

///|
/// 文本视图：与报告里其它表格同样的「数值 + 缩进 + 路径」风格，可整份快照。
///
/// 表里只出 `cumulative - min` 这一个口径，并在抬头写明它是「多写了几份」，
/// 免得被当成 `wasteful paths` 的 `wasted_bytes`。
pub fn render_efficiency_view(
  report : EfficiencyReport,
  options : EfficiencyViewOptions,
) -> String {
  let rows = efficiency_view_rows(report, options)
  let builder = StringBuilder()
  builder.write_string(
    "efficiency: \{percent(report.efficiency.score())} (\{report.efficiency.min_bytes}/\{report.efficiency.cumulative_bytes})\n",
  )
  let scope = match options.path {
    Some(path) => path
    None => "/"
  }
  builder.write_string(
    "paths by extra writes (cumulative - min), scope: \{scope}, showing \{rows.length()}:\n",
  )
  if rows.is_empty() {
    builder.write_string("  (none)\n")
    return builder.to_string()
  }
  for row in rows {
    builder.write_string(
      "  \{row.size} bytes  cumulative \{row.cumulative_bytes}  min \{row.min_bytes}  x\{row.versions}  \{row.path}\n",
    )
  }
  builder.to_string()
}

///|
/// JSON 视图：字段与文本逐项对齐，脚本消费时不用再解析人类可读的那几列。
pub fn efficiency_view_to_json(
  report : EfficiencyReport,
  options : EfficiencyViewOptions,
) -> Json {
  Json::object({
    "schemaVersion": Json(efficiency_view_schema_version),
    // 总分与分子分母一起出，方便脚本拿表里的行反推、交叉验证
    "efficiency": Json::object({
      "score": Json(round6(report.efficiency.score())),
      "minBytes": Json(report.efficiency.min_bytes),
      "cumulativeBytes": Json(report.efficiency.cumulative_bytes),
    }),
    "path": match options.path {
      Some(path) => Json(path)
      None => Json::null()
    },
    "top": Json(options.top),
    "metric": Json("cumulativeMinusMin"),
    "paths": Json(efficiency_view_rows(report, options).map(row_to_json)),
  })
}

///|
pub fn efficiency_view_to_json_string(
  report : EfficiencyReport,
  options : EfficiencyViewOptions,
) -> String {
  efficiency_view_to_json(report, options).stringify(indent=2)
}

///|
fn row_to_json(row : PathEfficiencyRow) -> Json {
  Json::object({
    "path": Json(row.path),
    "versions": Json(row.versions),
    "cumulativeBytes": Json(row.cumulative_bytes),
    "minBytes": Json(row.min_bytes),
    "size": Json(row.size),
  })
}
