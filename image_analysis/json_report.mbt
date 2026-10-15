///|
/// JSON 报告的结构版本号。字段有增删改时递增，供 P4 的门禁判定做兼容处理。
pub let json_report_schema_version : Int32 = 2

///|
/// 报告转 JSON：结构化字段，供 P4 的门禁判定消费。
///
/// 字段布局：
/// - `schemaVersion` / `layers`：概览
/// - `image.currentBytes` / `currentPaths` / `writtenBytes`：体积口径
/// - `image.wastedBytes` / `image.userWastedPercent`：dive 的同名出口
/// - `image.wasted.overwritten` / `image.wasted.deleted`：浪费拆分（本仓口径）
/// - `efficiency.score`(0..1) + `minBytes` / `cumulativeBytes`：分子分母，便于复核
/// - `layerStats[]`：每层的 added / overwritten / deleted 路径数与写入 / 浪费字节
/// - `wastefulPaths[]`：浪费最多的路径，含 `writes` 与 `currentLayer`
/// - `largestDirectories[]`：占用最大的目录
///
/// 浮点分数保留 6 位小数，保证文本快照稳定。
pub fn report_to_json(report : Report) -> Json {
  Json::object({
    "schemaVersion": Json(json_report_schema_version),
    "layers": Json(report.layers),
    "image": Json::object({
      "currentBytes": Json(report.final_file_bytes),
      "currentPaths": Json(report.final_paths),
      "writtenBytes": Json(report.total_bytes),
      "userBytes": Json(report.user_bytes),
      "wastedBytes": Json(wasted_bytes(report)),
      "userWastedPercent": Json(round6(user_wasted_percent(report))),
      "wasted": Json::object({
        "overwritten": Json(report.overwritten_wasted),
        "deleted": Json(report.deleted_wasted),
      }),
    }),
    "efficiency": Json::object({
      "score": Json(round6(report.efficiency.score())),
      "minBytes": Json(report.efficiency.min_bytes),
      "cumulativeBytes": Json(report.efficiency.cumulative_bytes),
    }),
    "layerStats": Json(report.usages.map(usage_to_json)),
    "wastefulPaths": Json(report.wasteful_paths.map(path_size_to_json)),
    "largestDirectories": Json(report.hotspots.map(hotspot_to_json)),
  })
}

///|
fn usage_to_json(usage : LayerUsage) -> Json {
  Json::object({
    "layer": Json(usage.layer),
    "addedPaths": Json(usage.added_paths),
    "overwrittenPaths": Json(usage.overwritten_paths),
    "deletedPaths": Json(usage.deleted_paths),
    "writtenBytes": Json(usage.written_bytes),
    "wastedBytes": Json(usage.wasted_bytes),
    "erasedBytes": Json(usage.erased_bytes),
  })
}

///|
fn path_size_to_json(size : PathSize) -> Json {
  Json::object({
    "path": Json(size.path),
    "currentBytes": Json(size.size),
    "wastedBytes": Json(size.wasted_bytes),
    "writes": Json(size.writes),
    "deleted": Json(size.deleted),
    "currentLayer": match size.current_layer {
      Some(layer) => Json(layer)
      None => Json::null()
    },
  })
}

///|
fn hotspot_to_json(spot : Hotspot) -> Json {
  Json::object({
    "path": Json(spot.path),
    "cumulativeBytes": Json(spot.cumulative_bytes),
    "files": Json(spot.files),
  })
}

///|
/// 保留 6 位小数，避免浮点尾数把 JSON 快照搅乱。
fn round6(value : Double) -> Double {
  (value * 1000000.0).round() / 1000000.0
}

///|
/// 报告转 JSON 文本（缩进 2 空格），抄起来直接能 diff。
pub fn report_to_json_string(report : Report) -> String {
  report_to_json(report).stringify(indent=2)
}
