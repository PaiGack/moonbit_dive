///|
/// 解压好的层：与 `layers` 下标对齐，`raw` 是这一层的 tar 字节（已解压）。
///
/// 拆出这一类型是为了让「解压」与「用」分开：叠树与分析都要吃同一批层，
/// 先解压一次存下来，两条链路再各取所需，不必各自再解一遍。
pub(all) struct DecompressedLayers {
  /// 逐层的 tar 字节（下标即层号）
  raws : Array[Bytes]
  /// 解压次数。测试用它钉住「一批层只解压一遍」——
  /// 这层保证不该靠人读代码维持（issue #52）。
  decompressed : Int32
} derive(Eq, Debug)

///|
pub extend DecompressedLayers with Eq::{equal, not_equal}

///|
pub extend DecompressedLayers with @debug.Debug::{to_repr}

///|
pub impl Show for DecompressedLayers with fn to_string(self) {
  "DecompressedLayers(\{self.raws.length()} layers, \{self.decompressed} decompress call(s))"
}

///|
pub extend DecompressedLayers with Show::{to_string, output}

///|
/// 某一层之后的树视图。
///
/// dive 的交互界面核心是「在层之间切换，看这层的文件树长什么样」。本模块把
/// 「把树裁到第 n 层」这件事抽出来：给定逐层快照，返回第 `layer` 层应用完之后的树。
/// 它不是新语义，只是 `snapshot` 的时间切片，供 CLI 逐层浏览。
pub(all) struct LayerView {
  /// 该视图对应的层号（从 0 开始）
  layer : Int32
  /// 应用完第 `layer` 层之后的树
  tree : FileTree
  /// 该层的 diff（相对第 `layer - 1` 层；第 0 层与空树比）
  diff : Diff
  /// 聚合 diff：第 `layer` 层的树相对**第 0 层之前**（空树）的整体差异。
  ///
  /// 原版 dive 的 `CompareAllLayers` 档位就是它，且口径是「这期间被碰过」：
  /// 第 0 层写过、第 2 层又改回原样的路径仍算 `modified`（见 `diff_aggregate`）。
  aggregate : Diff
  /// 聚合档下每一层的体积（该层树上所有文件字节合计），下标即层号。
  ///
  /// 有了它，「聚合档的体积」也能按同一条比较区间算：
  /// `[:l].last() - ([:base].last() ?? 0)` 就是「这段区间整体涨了多少」，
  /// 与聚合 diff 落在同一把尺子上（`aggregate_size_delta`）。
  layer_sizes : Array[Int32]
} derive(Debug)

///|
pub extend LayerView with @debug.Debug::{to_repr}

///|
pub impl Show for LayerView with fn to_string(self) {
  "LayerView(L\{self.layer}: \{self.tree.size()} paths, \{self.diff})"
}

///|
pub extend LayerView with Show::{to_string, output}

///|
/// 按 media type 逐层解压，得到可以反复取用的层数据。
///
/// `layers` 与 `media_types` 的口径同 `apply_layers_with_diffs`；
/// 返回的 `raws` 与 `layers` 一一对应。**每层只解压一次**。
pub fn decompress_layers(
  layers : Array[BytesView],
  media_types~ : Array[String] = [],
) -> DecompressedLayers raise LayerError {
  let raws = []
  for index, stream in layers {
    let media_type = if index < media_types.length() {
      media_types[index]
    } else {
      "none"
    }
    let algorithm = compression_of(media_type)
    let raw = decompress_layer(stream, algorithm) catch {
      err => raise Decompress(err)
    }
    raws.push(raw)
  }
  { raws, decompressed: layers.length(), }
}

///|
/// 逐层浏览一个镜像：每层的树形状 + 该层的 diff。
///
/// `layers` 与 `media_types` 的口径同 `apply_layers_with_diffs`。
/// 返回数组与层一一对应，第 `i` 个元素的 `tree` 是「应用完第 i 层」的样子。
pub fn browse_layers(
  layers : Array[BytesView],
  media_types~ : Array[String] = [],
) -> Array[LayerView] raise LayerError {
  browse_decompressed(decompress_layers(layers, media_types~))
}

///|
/// 从已解压的层建逐层视图：语义与 `browse_layers` 完全一致，
/// 只是不再吃掉原始（可能带压缩的）字节，因此调用方可以把同一批解压结果
/// 也交给分析层，避免解压两遍（issue #52）。
pub fn browse_decompressed(
  decompressed : DecompressedLayers,
) -> Array[LayerView] {
  let tree = FileTree::new()
  let views : Array[LayerView] = []
  let diffs : Array[Diff] = []
  let layer_sizes : Array[Int32] = []
  // 聚合档的比较起点：第 0 层之前的空树；第 0 层应用完之后换成它的快照。
  let empty = FileTree::new()
  for index, raw in decompressed.raws {
    let before = tree.snapshot()
    // 已经解压过的层不该再出 tar 错：真出了就是「解压产物」这一契约被破坏，
    // 属于程序缺陷，就地炸出来，别把错误吞成一次静默的空视图
    match apply_layer_boxed(tree, raw, index) {
      Ok(_) => ()
      Err(err) => abort("applying decompressed layer \{index} failed: \{err}")
    }
    let snapshot = tree.snapshot()
    let diff = diff_snapshots(before, snapshot, index - 1, index)
    // 逐层 diff 先入账：聚合档吃的就是「区间内各层的 diff」，含当前这一层
    diffs.push(diff)
    // 聚合档复用同一次快照与已经算好的逐层 diff，不回 tar 重新叠层
    let aggregate = if index == 0 {
      diff_aggregate(empty, snapshot, diffs, -1, 0)
    } else {
      diff_aggregate(views[0].tree, snapshot, diffs, 0, index)
    }
    layer_sizes.push(total_file_bytes(snapshot))
    views.push({ layer: index, tree: snapshot, diff, aggregate, layer_sizes, })
  }
  views
}

///|
/// 树上所有文件节点的字节合计（目录、链接按 0 计）。
fn total_file_bytes(tree : FileTree) -> Int32 {
  let mut total = 0
  for path, node in tree.nodes {
    if path != "/" && node.is_file() {
      total = total + node.size
    }
  }
  total
}

///|
/// 聚合档的体积差：从 `base` 层（不含，`-1` 表示空树）到当前层的整体涨跌。
///
/// 与聚合 diff 同一条区间：`base` 取 `layer - 1` 时答案与逐层档一致
/// （拿某一层的快照差），取 `-1` 时就是「相对空树一共写了多少」。
/// `layer_sizes` 只到 `self.layer`，越界时退化成 0，不把「没有的层」当成一份数据。
pub fn LayerView::aggregate_size_delta(self : LayerView, base : Int32) -> Int32 {
  let after = self.layer_size(self.layer)
  let before = if base < 0 { 0 } else { self.layer_size(base) }
  after - before
}

///|
/// 视图里某一层的体积；越界给 0。
pub fn LayerView::layer_size(self : LayerView, layer : Int32) -> Int32 {
  if layer < 0 || layer >= self.layer_sizes.length() {
    0
  } else {
    self.layer_sizes[layer]
  }
}

///|
/// 某个视图里「这一层变了什么」的路径清单（added / modified / removed 合并）。
pub fn LayerView::changed_paths(self : LayerView) -> Array[String] {
  let result = []
  for path in self.diff.added {
    result.push(path)
  }
  for path in self.diff.modified {
    result.push(path)
  }
  for path in self.diff.removed {
    result.push(path)
  }
  result.sort_by(path_order)
  result
}

///|
/// 聚合档下「这段区间整体变了什么」的路径清单，口径同 `changed_paths`，
/// 只是读 `aggregate` 而不是 `diff`。
pub fn LayerView::aggregate_changed_paths(self : LayerView) -> Array[String] {
  let result = []
  for path in self.aggregate.added {
    result.push(path)
  }
  for path in self.aggregate.modified {
    result.push(path)
  }
  for path in self.aggregate.removed {
    result.push(path)
  }
  result.sort_by(path_order)
  result
}

///|
/// 把「已保证不会出错」的 `apply_layer` 焊成 Result，供 `browse_decompressed`
/// 把契约破坏当程序缺陷报出来（`abort` 只在 `noraise` 上下文里可用）。
fn apply_layer_boxed(
  tree : FileTree,
  raw : Bytes,
  layer : Int32,
) -> Result[Unit, TarError] noraise {
  try apply_layer(tree, raw, layer) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
}

///|
/// 在视图里按路径前缀筛出一棵子树，供 CLI 的 `--path` 使用。
///
/// 保留 `prefix` 自身及其子树，外加它沿途的祖先目录作为缩进参照——
/// 少了祖先目录，`render_tree` 会把这些节点当孤儿，视图里只剩一个 `/`。
/// `prefix` 找不到时返回空树。
pub fn LayerView::subtree(self : LayerView, prefix : String) -> FileTree {
  let normalized = match normalize_path(prefix) {
    Ok(path) => path
    Err(_) => return FileTree::new()
  }
  let result = FileTree::new()
  // 先确认前缀下真有条目：没有就返回空树，别把沿途祖先当成结果
  let hit = self.tree.paths().any(fn(path) { path_is_under(path, normalized) })
  if !hit {
    return result
  }
  let wanted = self.tree
    .paths()
    .filter(fn(path) {
      path_is_under(path, normalized) || path_is_under(normalized, path)
    })
  for path in wanted {
    match self.tree.get(path) {
      Some(node) => {
        let cloned = Node::new(
          node.path,
          node.kind,
          size=node.size,
          mode=node.mode,
          layer=node.layer,
          mtime=node.mtime,
        )
        result.nodes.set(path, cloned)
        result.attach(cloned)
      }
      None => ()
    }
  }
  result.layers = self.tree.layers
  result
}
