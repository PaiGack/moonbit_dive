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
pub fn hotspots(
  tree : @layer_tree.FileTree,
  depth~ : Int32 = 1,
  limit~ : Int32 = 10,
) -> Array[Hotspot] {
  let files = file_sizes(tree)
  let result = []
  for path in tree.paths() {
    let node = match tree.get(path) {
      Some(node) => node
      None => continue
    }
    if !node.is_dir() {
      continue
    }
    if depth >= 0 && @layer_tree.path_depth(path) > depth {
      continue
    }
    let mut total = 0
    let mut count = 0
    for file_path, size in files {
      if @layer_tree.path_is_under(file_path, path) {
        total = total + size
        count = count + 1
      }
    }
    result.push({
      path,
      cumulative_bytes: total,
      files: count,
      wasted_bytes: 0,
    })
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
