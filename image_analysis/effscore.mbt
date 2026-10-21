///|
/// efficiency score：min / cumulative。
///
/// 口径严格对齐 dive 的 `dive/filetree/efficiency.go`：
///
/// - 按**路径**聚合，跨所有层收集这条路径出现过的版本
/// - `cumulative` 是该路径所有写过的字节数之和（重复写会累加）
/// - `min_discovered` 是所有版本里最小的那个字节数
/// - 分数 = Σ min_discovered / Σ cumulative
///
/// 所以「同一路径被写两次、大小相同」不会被扣分（min == 单次大小），
/// 但「小文件被大内容覆盖」会明显掉分：这正是 dive 的口径。
/// 被 whiteout 删掉的路径计入 cumulative（原大小），min 记 0；目录 whiteout
/// 按子树里各文件的累计大小展开。
/// `cumulative` 为 0（空镜像或全是空文件）时定义成 `1.0`。
pub(all) struct Efficiency {
  /// Σ 各路径出现过的最小字节数
  min_bytes : Int32
  /// Σ 各路径所有版本字节数之和
  cumulative_bytes : Int32
} derive(Eq, Debug)

///|
pub extend Efficiency with Eq::{equal, not_equal}

///|
pub extend Efficiency with @debug.Debug::{to_repr}

///|
pub impl Show for Efficiency with fn to_string(self) {
  "\{self.score()} (\{self.min_bytes}/\{self.cumulative_bytes})"
}

///|
pub extend Efficiency with Show::{to_string, output}

///|
/// 分数：`min / cumulative`，值域 `[0, 1]`。
pub fn Efficiency::score(self : Efficiency) -> Double {
  if self.cumulative_bytes <= 0 {
    1.0
  } else {
    self.min_bytes.to_double() / self.cumulative_bytes.to_double()
  }
}

///|
/// 浪费比例：`1 - score`。
pub fn Efficiency::wasted_ratio(self : Efficiency) -> Double {
  1.0 - self.score()
}

///|
/// 一条路径在整镜像里的版本记录：写过的字节（含 0 表示被删）/ 最小的那个版本。
pub(all) struct PathEfficiency {
  path : String
  cumulative_bytes : Int32
  min_bytes : Int32
  /// 出现过几个版本；≥2 说明这条路径拖累了分数
  versions : Int32
} derive(Eq, Debug)

///|
pub extend PathEfficiency with Eq::{equal, not_equal}

///|
pub extend PathEfficiency with @debug.Debug::{to_repr}

///|
pub impl Show for PathEfficiency with fn to_string(self) {
  "\{self.path}: cumulative \{self.cumulative_bytes}, min \{self.min_bytes}, versions \{self.versions}"
}

///|
pub extend PathEfficiency with Show::{to_string, output}

///|
/// 逐路径的 efficiency 统计 + 总分。
pub(all) struct EfficiencyReport {
  efficiency : Efficiency
  /// 被写过多版的路径（含被删的），按节省空间从大到小排；同分按路径序
  paths : Array[PathEfficiency]
} derive(Eq, Debug)

///|
pub extend EfficiencyReport with Eq::{equal, not_equal}

///|
pub extend EfficiencyReport with @debug.Debug::{to_repr}

///|
pub impl Show for EfficiencyReport with fn to_string(self) {
  self.efficiency.to_string()
}

///|
pub extend EfficiencyReport with Show::{to_string, output}

///|
/// 从「每个路径在各层的版本字节数」算 efficiency。
///
/// `versions[path]` 是该路径按层序记录的版本大小（0 表示被某层删掉）。
/// 这是公式的底层形式：`analyze_layers` 之外的单测直接喂数据就能验算。
pub fn efficiency_of_versions(
  versions : Map[String, Array[Int32]],
) -> EfficiencyReport {
  efficiency_of_layer_versions(sparse_versions(versions))
}

///|
/// 把「每条路径一个按层序排好的数组」转成稀疏的「层下标 -> 字节数」。
///
/// 老形态是 `efficiency_of_versions` 的输入约定，这里只做一次转换，
/// 聚合逻辑与生产链路共用同一份（避免两条口径慢慢漂移）。
fn sparse_versions(
  versions : Map[String, Array[Int32]],
) -> Map[String, Map[Int32, Int32]] {
  let result : Map[String, Map[Int32, Int32]] = Map([])
  for path, sizes in versions {
    let bucket : Map[Int32, Int32] = Map([])
    for index, size in sizes {
      bucket.set(index, size)
    }
    result.set(path, bucket)
  }
  result
}

///|
/// 从稀疏版本表算 efficiency：`min` 与 `cumulative` 都只过一遍每个路径写过的层。
pub fn efficiency_of_layer_versions(
  versions : Map[String, Map[Int32, Int32]],
) -> EfficiencyReport {
  let paths = []
  let mut min_total = 0
  let mut cumulative_total = 0
  for path, bucket in versions {
    if bucket.is_empty() {
      continue
    }
    let mut cumulative = 0
    let mut smallest = 0
    let mut seen = 0
    for _, size in bucket {
      cumulative = cumulative + size
      if seen == 0 || size < smallest {
        smallest = size
      }
      seen = seen + 1
    }
    min_total = min_total + smallest
    cumulative_total = cumulative_total + cumulative
    if seen >= 2 {
      paths.push({
        path,
        cumulative_bytes: cumulative,
        min_bytes: smallest,
        versions: seen,
      })
    }
  }
  paths.sort_by(fn(left, right) {
    let left_waste = left.cumulative_bytes - left.min_bytes
    let right_waste = right.cumulative_bytes - right.min_bytes
    if left_waste != right_waste {
      right_waste - left_waste
    } else {
      @layer_tree.path_order(left.path, right.path)
    }
  })
  {
    efficiency: { min_bytes: min_total, cumulative_bytes: cumulative_total, },
    paths,
  }
}

///|
/// 从分析结果算 efficiency。
///
/// `analyze_layers` 在记账时留下了逐路径的版本表，这里只做聚合。
/// 走 `efficiency_of_versions` 之外的分析结果（例如手工构造的 `Analysis`）
/// 若没带版本表，按空镜像处理，返回满分。
pub fn Analysis::efficiency(self : Analysis) -> EfficiencyReport {
  match self.versions {
    Some(table) => efficiency_of_layer_versions(table.versions)
    None => efficiency_of_layer_versions(Map([]))
  }
}
