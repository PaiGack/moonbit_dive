///|
/// 单个路径在整镜像里的体积账。
///
/// `size` 是该路径「最后一次写入」的字节数；被后层覆盖、或被 whiteout 删掉的
/// 旧版本算作浪费，逐层累计到 `wasted_bytes`。
pub(all) struct PathSize {
  /// 这个路径（报告里要能认出来是哪个文件）
  path : String
  /// 路径最后一次写入的内容大小（目录与链接为 0）
  mut size : Int32
  /// 仍有层引用、但已不再生效的字节数
  mut wasted_bytes : Int32
  /// 覆盖过这个路径的层数（被删除的层不计）
  mut writes : Int32
  /// 是否被某一层删除过（whiteout / opaque）
  mut deleted : Bool
  /// 当前内容由哪一层写入；已删除时为 `None`
  mut current_layer : Int32?
} derive(Eq, Debug)

///|
pub extend PathSize with Eq::{equal, not_equal}

///|
pub extend PathSize with @debug.Debug::{to_repr}

///|
pub impl Show for PathSize with fn to_string(self) {
  let state = match self.current_layer {
    Some(layer) => "L\{layer}"
    None => "deleted"
  }
  "\{self.size} bytes (\{state}), wasted \{self.wasted_bytes}, writes \{self.writes}"
}

///|
pub extend PathSize with Show::{to_string, output}

///|
/// 新建一条空的路径账。
pub fn PathSize::new(path : String) -> PathSize {
  {
    path,
    size: 0,
    wasted_bytes: 0,
    writes: 0,
    deleted: false,
    current_layer: None,
  }
}

///|
/// 单层的体积账。
pub(all) struct LayerUsage {
  layer : Int32
  /// 本层写入的全新路径数（树里此前不存在）
  mut added_paths : Int32
  /// 本层改写已有路径数
  mut overwritten_paths : Int32
  /// 本层写入的字节数（含覆盖掉的旧内容）
  mut written_bytes : Int32
  /// 本层覆盖掉的旧内容字节数
  mut wasted_bytes : Int32
  /// opaque 抹掉的旧字节数（不在 `wasted_bytes` 里）
  mut erased_bytes : Int32
  /// 本层删除的路径数（含 whiteout 的子树）
  mut deleted_paths : Int32
} derive(Eq, Debug)

///|
pub extend LayerUsage with Eq::{equal, not_equal}

///|
pub extend LayerUsage with @debug.Debug::{to_repr}

///|
pub impl Show for LayerUsage with fn to_string(self) {
  "L\{self.layer}: +\{self.added_paths} ~\{self.overwritten_paths} -\{self.deleted_paths}, wrote \{self.written_bytes} bytes, wasted \{self.wasted_bytes}, erased \{self.erased_bytes}"
}

///|
pub extend LayerUsage with Show::{to_string, output}

///|
/// 新建一层的空账。
pub fn LayerUsage::new(layer : Int32) -> LayerUsage {
  {
    layer,
    added_paths: 0,
    overwritten_paths: 0,
    written_bytes: 0,
    wasted_bytes: 0,
    erased_bytes: 0,
    deleted_paths: 0,
  }
}

///|
/// 一张镜像的体积分析结果。
///
/// 「当前」指最后一层应用完之后的状态；`wasted_*` 覆盖所有层，含被删掉的内容。
pub(all) struct Analysis {
  /// 层数
  mut layers : Int32
  /// 每个路径的体积账。插入顺序即层序，同层内按写入先后
  sizes : Map[String, PathSize]
  /// 每层的写入 / 浪费 / 删除统计
  usages : Array[LayerUsage]
  /// 当前树上文件（含硬链接）的字节数合计
  mut final_file_bytes : Int32
  /// 当前树上占用空间的路径数（文件、目录、链接都算）
  mut final_paths : Int32
  /// 跨层重复写入浪费的字节数：同一路径被写了两次以上，前几次的内容
  mut overwritten_wasted : Int32
  /// 被删除浪费的字节数：whiteout 与 opaque 抹掉的内容
  mut deleted_wasted : Int32
  /// 算 efficiency 用的逐路径版本表；只有 `analyze_layers` 会填
  mut versions : VersionTable?
} derive(Eq, Debug)

///|
pub extend Analysis with Eq::{equal, not_equal}

///|
pub extend Analysis with @debug.Debug::{to_repr}

///|
pub impl Show for Analysis with fn to_string(self) {
  "Analysis(layers=\{self.layers}, paths=\{self.final_paths}, bytes=\{self.final_file_bytes}, wasted=\{self.wasted_bytes()})"
}

///|
pub extend Analysis with Show::{to_string, output}

///|
/// 浪费掉的字节总数（覆盖写入 + 被删除）。
pub fn Analysis::wasted_bytes(self : Analysis) -> Int32 {
  self.overwritten_wasted + self.deleted_wasted
}

///|
/// 镜像里「写入过」的字节总数：当前内容 + 所有被浪费的内容。
pub fn Analysis::total_bytes(self : Analysis) -> Int32 {
  self.final_file_bytes + self.wasted_bytes()
}

///|
/// 用户自己写的字节：除第 0 层（base image）之外所有层的写入合计。
///
/// 对齐 dive 的 `userWastedPercent` 分母（`image/analysis.go` 里
/// `for idx, layer := range layers { if idx == 0 { continue } ... }`）：
/// base image 的内容被覆盖不该算用户的账。
///
/// 口径与 `total_bytes` 同源，只是砍掉第 0 层：累加每层的 `written_bytes`
/// **减去**该层吃掉的旧内容（`wasted` + `erased`）——`erased` 是 opaque 那一栏，
/// 与覆盖那条账互不重叠。层数 ≤ 1 时没有用户层，返回 0。
///
/// 结果夹在 0 以上：用户层写得比删得少时（「上来先清掉半个基础镜像」），
/// 净写入是负数，而它是 `user wasted` 的分母——负分母会让百分比失真，
/// 也会把「省了空间」读成「写了 -22GB」。减到 0 只是记账下限，不是谎报：
/// 分母为 0 时 `user_wasted_percent` 直接返回 0。
pub fn Analysis::user_bytes(self : Analysis) -> Int32 {
  let mut total = 0
  for usage in self.usages {
    if usage.layer == 0 {
      continue
    }
    total = total +
      usage.written_bytes -
      usage.wasted_bytes -
      usage.erased_bytes
  }
  if total < 0 {
    0
  } else {
    total
  }
}

///|
/// 某路径的体积账；从未被写入过的路径返回 `None`。
pub fn Analysis::path_size(self : Analysis, path : String) -> PathSize? {
  self.sizes.get(path)
}

///|
/// 按浪费字节从大到小排的路径，只列有浪费的，长度不超过 `limit`。
pub fn Analysis::waste_ranking(
  self : Analysis,
  limit~ : Int32 = 10,
) -> Array[PathSize] {
  let items = []
  for _, size in self.sizes {
    if size.wasted_bytes > 0 {
      items.push(size)
    }
  }
  items.sort_by(fn(left, right) {
    if left.wasted_bytes != right.wasted_bytes {
      right.wasted_bytes - left.wasted_bytes
    } else {
      // 浪费字节相同时按路径稳定排序，保证报告可快照
      @layer_tree.path_order(left.to_string(), right.to_string())
    }
  })
  if limit >= 0 && items.length() > limit {
    items[:limit].to_owned()
  } else {
    items
  }
}

///|
/// efficiency 的原料：每个路径在每一层被写成的字节数。
///
/// 值 `0` 表示「这一层把它删了」（whiteout / opaque），但不代表它没占过空间：
/// 那 0 会参与 min 的计算，原大小则早已计入 cumulative。
pub(all) struct VersionTable {
  /// 路径 -> (层下标 -> 该层的字节数)。稀疏：只记真正写过的层。
  versions : Map[String, Map[Int32, Int32]]
} derive(Eq, Debug)

///|
pub extend VersionTable with Eq::{equal, not_equal}

///|
pub extend VersionTable with @debug.Debug::{to_repr}

///|
/// 空表：没有任何写入，对应空镜像（efficiency 定义成满分）。
pub fn VersionTable::new() -> VersionTable {
  { versions: Map([]), }
}
