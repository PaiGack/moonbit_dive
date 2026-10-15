///|
/// 把 `image_analysis` 的分析结果压成渲染要的 `DetailSource`。
///
/// 抽出来的动机：`Analysis` 里的 `PathSize` 带 `wasted_bytes`（口径是「多写的部分」），
/// 而详情面板想给的是「各版本加起来 vs 只留一份」——两者不等。
///
/// 数字全部来自 `image_analysis` 的既有出口，**这里不重算**：
///
/// - 逐路径的 `versions` / `cumulative` / `min` / `size` 来自 `EfficiencyReport.paths`
///   （即 `cumulative - min` 那套精确值，与 efficiency 总分同源）
/// - `wasted` 取 `Report` 的 `wasted_bytes`（`Σ paths[].size`，dive 面板的口径），
///   不是「真实丢掉的字节」（`overwritten + deleted`）——面板与总分该说同一件事
/// - 下方那张表的行直接复用 `efficiency_view_rows`，与 `--efficiency` 视图同源
pub fn detail_source_of(
  analysis : @image_analysis.Analysis,
  report : @image_analysis.Report,
) -> DetailSource {
  let entries : Map[String, DetailEntry] = Map([])
  for row in analysis.efficiency().paths {
    entries.set(row.path, {
      versions: row.versions,
      cumulative: row.cumulative_bytes,
      min_bytes: row.min_bytes,
      size: row.cumulative_bytes - row.min_bytes,
    })
  }
  let top_wasteful = []
  for row in report.inefficient_paths {
    top_wasteful.push(
      (row.path, row.versions, row.cumulative_bytes - row.min_bytes),
    )
  }
  {
    entries,
    wasted: @image_analysis.wasted_bytes(report),
    total: report.final_file_bytes,
    efficiency: report.efficiency.score(),
    top_wasteful,
  }
}

///|
/// 从**已解压**的层建一次分析（详情面板要靠它）。
///
/// 收 `DecompressedLayers` 而不是原始字节：`browse_decompressed` 用的就是它，
/// 这里再解压一遍纯属白干（issue #52）。两条链路的产物形态仍然不同
/// （一个是树快照、一个是体积统计），但输入已经是同一批 tar 字节。
///
/// 返回的 `FileTree` 是分析过程中推进到最后一层的树，交给 `build_report`
/// 出热点——和 `browse_layers` 最后一张快照是同一棵树的内容。
pub fn analysis_of_decompressed(
  layers : @layer_tree.DecompressedLayers,
) -> (@image_analysis.Analysis, @image_analysis.Report)? {
  let tree = @layer_tree.FileTree::new()
  let analysis = @image_analysis.analyze_decompressed(tree, layers) catch {
    _ => return None
  }
  let report = @image_analysis.build_report(analysis, tree)
  Some((analysis, report))
}
