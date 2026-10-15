///|
/// 报告的输出口径：文本报告与 JSON 报告共用一份中间结构，
/// 保证两边数字永远一致。
pub(all) struct Report {
  layers : Int32
  /// 镜像当前占用（最后一层树上文件的字节合计）
  final_file_bytes : Int32
  /// 最后一层树上的路径数
  final_paths : Int32
  /// 累积写入的字节（= 当前占用 + 全部浪费）
  total_bytes : Int32
  /// 用户自己写的字节（**不含第 0 层**，即不含 base image）
  ///
  /// dive 的 `userWastedPercent` 分母就是它：base image 里被覆盖的内容
  /// 不该记到用户账上（`dive/image/analysis.go` 有 `if idx == 0 { continue }`）。
  /// 层数 ≤ 1 时恒为 0。
  user_bytes : Int32
  overwritten_wasted : Int32
  deleted_wasted : Int32
  efficiency : Efficiency
  /// 多写了几份最多的路径（`cumulative - min` 降序，最多 10 条）
  ///
  /// 与 `wasteful_paths` 是两个口径：那个是「空间实际丢在哪」，
  /// 这个是「是谁把分数拉下来的」。TUI 详情面板下方那张 inefficient files
  /// 表与这里的行一一对应（同一批数字，同一套排序）。
  inefficient_paths : Array[PathEfficiencyRow]
  usages : Array[LayerUsage]
  /// 浪费最多的路径，最多 10 条
  wasteful_paths : Array[PathSize]
  /// 占用最大的目录，最多 10 条
  hotspots : Array[Hotspot]
} derive(Eq, Debug)

///|
pub extend Report with Eq::{equal, not_equal}

///|
pub extend Report with @debug.Debug::{to_repr}

///|
pub impl Show for Report with fn to_string(self) {
  render_text_report(self)
}

///|
pub extend Report with Show::{to_string, output}

///|
/// 把分析结果整理成报告：文本与 JSON 都从这里出。
pub fn build_report(analysis : Analysis, tree : @layer_tree.FileTree) -> Report {
  {
    layers: analysis.layers,
    final_file_bytes: analysis.final_file_bytes,
    final_paths: analysis.final_paths,
    total_bytes: analysis.total_bytes(),
    user_bytes: analysis.user_bytes(),
    overwritten_wasted: analysis.overwritten_wasted,
    deleted_wasted: analysis.deleted_wasted,
    efficiency: analysis.efficiency().efficiency,
    // 面板要的那张表与 `--efficiency` 视图同源：精确的 `cumulative - min`，
    // 不是「最终大小 × 版本数」那种近似（issue #72）
    inefficient_paths: efficiency_view_rows(
      analysis.efficiency(),
      EfficiencyViewOptions::new(top=10),
    ),
    usages: analysis.usages,
    wasteful_paths: analysis.waste_ranking(),
    hotspots: hotspots(tree),
  }
}

///|
/// 百分比：保留一位小数，便于快照稳定。
pub fn percent(value : Double) -> String {
  let scaled = (value * 1000.0).round() / 10.0
  "\{scaled}%"
}

///|
/// 文本报告：层列表 + 体积 + 浪费 + efficiency。
///
/// 每行都是固定格式，数字全部来自 `Report`，可以整份快照。
pub fn render_text_report(report : Report) -> String {
  let builder = StringBuilder()
  builder.write_string("layers: \{report.layers}\n")
  for usage in report.usages {
    builder.write_string(render_usage(usage))
  }
  builder.write_string("image:\n")
  builder.write_string(
    "  current: \{report.final_file_bytes} bytes in \{report.final_paths} paths\n",
  )
  builder.write_string("  written: \{report.total_bytes} bytes\n")
  builder.write_string(
    "  user written: \{report.user_bytes} bytes (all layers but the base)\n",
  )
  builder.write_string(
    "  wasted: \{wasted_bytes(report)} bytes (\{percent(wasted_ratio(report))})\n",
  )
  builder.write_string(
    "    by path (cumulative - min): \{wasted_bytes(report)} bytes\n",
  )
  builder.write_string("    overwritten: \{report.overwritten_wasted} bytes\n")
  builder.write_string("    deleted: \{report.deleted_wasted} bytes\n")
  builder.write_string(
    "  user wasted: \{percent(user_wasted_percent(report))} of \{report.user_bytes} bytes\n",
  )
  builder.write_string(
    "efficiency: \{percent(report.efficiency.score())} (\{report.efficiency.min_bytes}/\{report.efficiency.cumulative_bytes})\n",
  )
  builder.write_string("wasteful paths:\n")
  if report.wasteful_paths.is_empty() {
    builder.write_string("  (none)\n")
  } else {
    for size in report.wasteful_paths {
      builder.write_string(
        "  \{size.wasted_bytes} bytes  x\{size.writes}  \{size.path}\n",
      )
    }
  }
  builder.write_string("largest directories:\n")
  if report.hotspots.is_empty() {
    builder.write_string("  (none)\n")
  } else {
    for spot in report.hotspots {
      builder.write_string(
        "  \{spot.cumulative_bytes} bytes  \{spot.files} files  \{spot.path}\n",
      )
    }
  }
  builder.to_string()
}

///|
/// 浪费的字节数：`Σ (cumulative - min)`，即逐路径「多写了几份」的合计。
///
/// **这是 dive 的口径**（`filetree/efficiency.go` 里每行的 `CumulativeSize`，
/// 面板与 `--json` 的 `inefficientBytes` 都取这个和），也是
/// `efficiency.wasted_ratio()` 的分子：`1 - score() == wasted_bytes / cumulative`。
///
/// 它**不等于**「真实丢掉的字节」（`overwritten_wasted + deleted_wasted`）：
/// 10 字节被 100 字节覆盖时是 90 vs 10（详见 `README.mbt.md` 的对照表）。
/// 两个数报告里都给，字段名各自写明口径。
pub fn wasted_bytes(report : Report) -> Int32 {
  report.efficiency.cumulative_bytes - report.efficiency.min_bytes
}

///|
/// 浪费占总写入的比例。注意它不等于 `1 - efficiency.score()`：
/// 分数按路径取 min，重复写同大小的内容不扣分，两者口径不同。
pub fn wasted_ratio(report : Report) -> Double {
  if report.total_bytes <= 0 {
    0.0
  } else {
    wasted_bytes(report).to_double() / report.total_bytes.to_double()
  }
}

///|
/// 用户浪费比例：`wasted_bytes / userBytes`，**分母不含 base image**。
///
/// 对齐 dive 的 `userWastedPercent`（`image/analysis.go` 跳过第 0 层）：
/// 用户只该为自己写的那几层负责，base image 里被覆盖的内容不算他的。
/// 层数 ≤ 1（没有用户层）时定义成 `0.0`，不返回 NaN。
pub fn user_wasted_percent(report : Report) -> Double {
  if report.user_bytes <= 0 {
    0.0
  } else {
    wasted_bytes(report).to_double() / report.user_bytes.to_double()
  }
}

///|
/// 单层的文本行。
fn render_usage(usage : LayerUsage) -> String {
  "  L\{usage.layer}: +\{usage.added_paths} ~\{usage.overwritten_paths} -\{usage.deleted_paths} paths, wrote \{usage.written_bytes} bytes, wasted \{usage.wasted_bytes + usage.erased_bytes} bytes\n"
}
