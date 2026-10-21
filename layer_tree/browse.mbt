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
  /// 原版 dive 的 `CompareAllLayers` 档位就是它，口径是「这期间被碰过」：
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
pub async fn decompress_layers(
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
pub async fn browse_layers(
  layers : Array[BytesView],
  media_types~ : Array[String] = [],
) -> Array[LayerView] raise LayerError {
  browse_decompressed(decompress_layers(layers, media_types~))
}

///|
/// 从已解压的层建逐层视图：语义与 `browse_layers` 完全一致，
/// 只是不再吃掉原始（可能带压缩的）字节，因此调用方可以把同一批解压结果
/// 也交给分析层，避免解压两遍（issue #52）。
///
/// 逐层 diff 的判等口径与 dive 的 `FileInfo::Compare` 一致：
/// `(kind, mode, uid, gid)` 全等才算没动过（`size` 也看，`mtime` 不看）。
/// 光靠这些认不出「同大小、同 mtime、内容不同」，所以这一档顺带按 tar
/// 算一遍每条 entry 的 sha256：大镜像上这是实打实的一遍读取，
/// `content_hashes = false` 可以关掉，换回「只比元数据 + size」的省法。
pub fn browse_decompressed(
  decompressed : DecompressedLayers,
  content_hashes~ : Bool = true,
) -> Array[LayerView] {
  let tree = FileTree::new()
  let views : Array[LayerView] = []
  let diffs : Array[Diff] = []
  let layer_sizes : Array[Int32] = []
  // 每层只扫一遍内容摘要：这一层的用来标 `snapshot`，上一层的用来标 `before`
  let mut previous_scan : ContentScan? = None
  // 聚合档的起点：第 0 层之前的空树（第 0 层与它比）
  let empty = FileTree::new()
  for index, raw in decompressed.raws {
    // 这一层的字节还没叠上去：`before` 与 `snapshot` 只差这一层。
    // 两份快照都要带内容摘要，`diff_snapshots` 才比得了「同大小不同内容」
    let before = tree.snapshot()
    // 已经解压过的层不该再出 tar 错：真出了就是「解压产物」这一契约被破坏，
    // 属于程序缺陷，就地炸出来，别把错误吞成一次静默的空视图
    apply_layer(tree, raw, index) catch {
      err => abort("applying decompressed layer \{index} failed: \{err}")
    }
    let snapshot = tree.snapshot()
    // 摘要按两条线标：这一层的写入盖在 `snapshot` 上，上一层的写入盖在 `before` 上
    if content_hashes {
      // 摘要是「按需」的：读不出来（残缺 tar）就当这一层没摘要，不打断浏览
      let scan = content_scan(raw)
      stamp_digests(snapshot, scan, index)
      match previous_scan {
        Some(previous) => stamp_digests(before, previous, index - 1)
        None => ()
      }
      previous_scan = Some(scan)
    }
    let diff = diff_snapshots(before, snapshot, index - 1, index)
    // 逐层 diff 先入账：聚合档吃的就是「区间内各层的 diff」，含当前这一层
    diffs.push(diff)
    // 聚合档复用同一次快照与已经算好的逐层 diff，不回 tar 重新叠层；
    // 起点是第 0 层的形状，`.snapshot()` 出一份独立的拷贝，
    // 免得与 `views[0].tree` 共用节点、被后面的层原地改写
    let aggregate = if index == 0 {
      diff_aggregate(empty, snapshot, diffs, -1, 0)
    } else {
      diff_aggregate(views[0].tree.snapshot(), snapshot, diffs, 0, index)
    }
    layer_sizes.push(total_file_bytes(snapshot))
    views.push({ layer: index, tree: snapshot, diff, aggregate, layer_sizes, })
  }
  views
}

///|
/// 把这一层的内容摘要标到快照上：只标「当前内容就是这一层写的」那些路径。
///
/// 快照里的节点是各自独立的拷贝，所以这里只会动到这一份快照自己的副本，
/// 不会顺着共享的节点对象改到别的视图。
fn stamp_digests(tree : FileTree, scan : ContentScan, layer : Int32) -> Unit {
  for path, hash in scan.hashes {
    match tree.nodes.get(path) {
      Some(node) =>
        if node.info.layer == layer {
          let changes = match node.digest {
            Some(previous) => previous.changes + 1
            None => 1
          }
          // 新建一个节点而不是改它：这份快照可能与更早的视图共用一个节点
          tree.set({ ..node, digest: Some({ changes, hash, }), })
        }
      None => ()
    }
  }
}

///|
/// 树上所有文件节点的字节合计（目录、链接按 0 计）。
fn total_file_bytes(tree : FileTree) -> Int32 {
  let mut total = 0
  for path, node in tree.nodes {
    if path != "/" && node.is_file() {
      total = total + node.info.size
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
/// 在视图里按路径前缀筛出一棵子树，供 CLI 的 `--path` 使用。
///
/// 保留 `prefix` 自身及其子树，外加它沿途的祖先目录作为缩进参照——
/// 少了祖先目录，`render_tree` 会把这些节点当孤儿，视图里只剩一个 `/`。
/// `prefix` 找不到时返回空树。
pub fn LayerView::subtree(self : LayerView, prefix : String) -> FileTree {
  let normalized = normalize_path(prefix) catch { _ => return FileTree::new() }
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
    // 节点不可变，子视图直接指着同一份节点：`LayerView` 本身不再演进，
    // 没有谁会把它改到脚底下
    match self.tree.get(path) {
      Some(node) => {
        result.nodes.set(path, node)
        result.attach(node)
      }
      None => ()
    }
  }
  result.layers = self.tree.layers
  result
}
