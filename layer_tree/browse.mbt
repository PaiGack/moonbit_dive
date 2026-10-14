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
/// 逐层浏览一个镜像：每层的树形状 + 该层的 diff。
///
/// `layers` 与 `media_types` 的口径同 `apply_layers_with_diffs`。
/// 返回数组与层一一对应，第 `i` 个元素的 `tree` 是「应用完第 i 层」的样子。
pub fn browse_layers(
  layers : Array[BytesView],
  media_types~ : Array[String] = [],
) -> Array[LayerView] raise LayerError {
  let tree = FileTree::new()
  let views = []
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
    let before = tree.snapshot()
    apply_layer(tree, raw, index) catch {
      err => raise Tar(err)
    }
    let diff = diff_snapshots(before, tree.snapshot(), index - 1, index)
    views.push({ layer: index, tree: tree.snapshot(), diff, })
  }
  views
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
