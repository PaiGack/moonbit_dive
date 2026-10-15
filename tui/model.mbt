///|
/// 把 `image_analysis` 的分析结果压成渲染要的 `DetailSource`。
///
/// 抽出来的动机：`Analysis` 里的 `PathSize` 带 `wasted_bytes`（口径是「多写的部分」），
/// 而详情面板想给的是「各版本加起来 vs 只留一份」——两者不等。
/// 这里用 `versions` + `sizes` 重算一遍，口径写在注释里，免得后人拿错字段。
pub fn detail_source_of(
  analysis : @image_analysis.Analysis,
  report : @image_analysis.Report,
) -> DetailSource {
  let entries : Map[String, DetailEntry] = Map([])
  // 每个路径的「版本数」与「各版本大小」来自 VersionTable；没有它时退化成
  // PathSize 的单份记录（旧数据源可能不填 versions）
  match analysis.versions {
    Some(table) =>
      for path, layers in table.versions {
        let node_size = match analysis.path_size(path) {
          Some(size) => size.size
          None => 0
        }
        entries.set(path, {
          versions: layers.length(),
          // 每一版大小按最终大小近似：tar 层里没有保留历史大小，
          // 这里只保证「多写了几次」这件事可见，不假装精确
          cumulative: node_size * layers.length(),
          min_bytes: node_size,
        })
      }
    None => ()
  }
  {
    entries,
    wasted: report.overwritten_wasted + report.deleted_wasted,
    total: report.final_file_bytes,
    efficiency: report.efficiency.score(),
  }
}

///|
/// 从逐层视图建一次分析（详情面板要靠它）。
///
/// `browse_layers` 已经解压过每一层，这里再 `analyze_layers` 走一遍是重复劳动，
/// 但两条链路的产物形态不同（一个是树快照、一个是体积统计），
/// 本轮先把两条都留着；合并成一次遍历单开 issue 做，不在接线里顺手改。
pub fn analysis_of_layers(
  layers : Array[BytesView],
) -> (@image_analysis.Analysis, @image_analysis.Report)? {
  let tree = @layer_tree.FileTree::new()
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    _ => return None
  }
  let report = @image_analysis.build_report(analysis, tree)
  Some((analysis, report))
}
