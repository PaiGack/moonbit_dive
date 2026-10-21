///|
/// 目录子树的热点：`cumulative_size` 是整棵子树的文件字节合计。
///
/// 与 `Analysis::waste_ranking` 的区别：那个看「浪费」，这个看「占用」，
/// 用来回答「镜像里最大的目录是哪个」。
pub(all) struct Hotspot {
  path : String
  /// 子树里所有文件的字节合计（含自身，若是文件则等于自身大小）
  cumulative_bytes : Int32
  /// 子树里的文件数
  files : Int32
  /// 子树里被覆盖 / 被删掉的字节合计，用来判断这个热点值不值得优化
  mut wasted_bytes : Int32
} derive(Eq, Debug)

///|
pub extend Hotspot with Eq::{equal, not_equal}

///|
pub extend Hotspot with @debug.Debug::{to_repr}

///|
pub impl Show for Hotspot with fn to_string(self) {
  "\{self.path}: \{self.cumulative_bytes} bytes / \{self.files} files"
}

///|
pub extend Hotspot with Show::{to_string, output}

///|
/// 给一棵树算各目录子树的热点，按 `cumulative_bytes` 从大到小排。
///
/// `depth` 限制返回的目录深度（`1` 只看根的直接子目录），便于把报告压到
/// 可读的篇幅；`limit` 限制条数，传负数表示不截断。
///
/// 口径是「一次父链上卷」而不是「每个目录扫一遍全表」：每个文件沿它的祖先
/// 各记一笔，代价是 `文件数 × 深度`，与目录数无关（issue #122）。
/// 老写法在 10⁵ 文件 / 10⁴ 目录的镜像上是 10⁹ 次前缀比较，几十秒起步。
pub fn hotspots(
  tree : @layer_tree.FileTree,
  depth~ : Int32 = 1,
  limit~ : Int32 = 10,
) -> Array[Hotspot] {
  let result : Array[Hotspot] = []
  let paths = tree.paths()
  let cumulative : Map[String, Int32] = Map([])
  let counted : Map[String, Int32] = Map([])
  for path, size in file_sizes(tree) {
    // `/a/b/c` -> `/a/b` -> `/a`：每级祖先都记一笔。根不在结果里，
    // 深度越界的层只跳过自己，更浅的祖先照记（`depth` 只裁剪输出）
    let mut current = @layer_tree.parent_path(path)
    while current != "/" {
      if depth < 0 || @layer_tree.path_depth(current) <= depth {
        let total : Int32 = match cumulative.get(current) {
          Some(total) => total
          None => 0
        }
        cumulative.set(current, total + size)
        let seen : Int32 = match counted.get(current) {
          Some(total) => total
          None => 0
        }
        counted.set(current, seen + 1)
      }
      current = @layer_tree.parent_path(current)
    }
  }
  // 只出候选：目录、且在 `depth` 之内。根不算（它不在 `paths()` 里，且全量没有信息量）
  for path in paths {
    let is_dir = match tree.get(path) {
      Some(node) => node.is_dir()
      None => false
    }
    if !is_dir || (depth >= 0 && @layer_tree.path_depth(path) > depth) {
      continue
    }
    let bytes : Int32 = match cumulative.get(path) {
      Some(total) => total
      None => 0
    }
    let files : Int32 = match counted.get(path) {
      Some(total) => total
      None => 0
    }
    result.push({ path, cumulative_bytes: bytes, files, wasted_bytes: 0, })
  }
  result.sort_by(fn(left, right) {
    if left.cumulative_bytes != right.cumulative_bytes {
      right.cumulative_bytes - left.cumulative_bytes
    } else {
      @layer_tree.path_order(left.path, right.path)
    }
  })
  if limit >= 0 && result.length() > limit {
    result[:limit].to_owned()
  } else {
    result
  }
}
