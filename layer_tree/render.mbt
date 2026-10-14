///|
/// 渲染选项：影响缩进树里的展示内容。
pub(all) struct RenderOptions {
  /// 在文件名后标注 `(N bytes)`
  show_size : Bool
  /// 在文件名后标注 `[L<n>]` 归属层
  show_layer : Bool
  /// 链接目标是否用 `->` / `==>` 带出
  show_links : Bool
} derive(Eq, Debug)

///|
pub extend RenderOptions with Eq::{equal, not_equal}

///|
pub extend RenderOptions with @debug.Debug::{to_repr}

///|
/// 默认渲染：带大小、带层号、带链接目标。
pub let default_render_options : RenderOptions = {
  show_size: true,
  show_layer: true,
  show_links: true,
}

///|
/// 只画路径树的精简渲染（对齐 dive 的默认视图）。
pub let minimal_render_options : RenderOptions = {
  show_size: false,
  show_layer: false,
  show_links: true,
}

///|
/// 用缩进文本树渲染整棵文件树。
///
/// 输出与 dive 的 `renderStringTreeBetween` 同形：每层缩进两个空格，
/// 目录名后带 `/`，链接带目标，顺序按路径字典序，保证快照稳定。
pub fn render_tree(tree : FileTree, options? : RenderOptions) -> String {
  let options = match options {
    Some(options) => options
    None => default_render_options
  }
  let builder = StringBuilder()
  builder.write_string("/\n")
  // 根节点在第 0 层，它的直接子节点缩进一级
  render_children(builder, tree.root, 1, options)
  builder.to_string()
}

///|
/// 只渲染某两棵树之间发生变化的路径，未变化的父目录作为上下文保留。
///
/// 用于 diff 视图：变化的文件始终缩进在其所属目录之下，
/// 视图上仍能看出层级；`L0` 比较空树时等价于整棵树的渲染。
pub fn render_tree_between(
  tree : FileTree,
  base : Int32,
  layer : Int32,
  options? : RenderOptions,
) -> String {
  let options = match options {
    Some(options) => options
    None => default_render_options
  }
  let builder = StringBuilder()
  builder.write_string("L\{base} -> L\{layer}\n")
  // 根的子节点缩进一级，与 render_tree 保持一致
  render_between(builder, tree.root, 1, base, layer, options)
  builder.to_string()
}

///|
fn render_children(
  builder : StringBuilder,
  node : Node,
  depth : Int32,
  options : RenderOptions,
) -> Unit {
  for child in node.children {
    write_indent(builder, depth)
    builder.write_string(item_text(child, options))
    builder.write_string("\n")
    if child.kind is NodeKind::Directory {
      render_children(builder, child, depth + 1, options)
    }
  }
}

///|
/// 递归渲染：只输出「归属层落在 (base, layer] 区间」的节点。
fn render_between(
  builder : StringBuilder,
  node : Node,
  depth : Int32,
  base : Int32,
  layer : Int32,
  options : RenderOptions,
) -> Unit {
  for child in node.children {
    let changed = child.layer > base && child.layer <= layer
    if child.kind is NodeKind::Directory {
      // 目录本身可能没变，但子树里有变化：把它当作上下文渲染出来，
      // 否则子节点的缩进会失去参照
      let subtree_changed = has_change_below(child, base, layer)
      if changed || subtree_changed {
        write_indent(builder, depth)
        builder.write_string(item_text(child, options))
        builder.write_string("\n")
      }
      render_between(builder, child, depth + 1, base, layer, options)
    } else if changed {
      write_indent(builder, depth)
      builder.write_string(item_text(child, options))
      builder.write_string("\n")
    }
  }
}

///|
/// 子树里是否还有「归属层落在 (base, layer]」的节点。
fn has_change_below(node : Node, base : Int32, layer : Int32) -> Bool {
  for child in node.children {
    if child.layer > base && child.layer <= layer {
      return true
    }
    if has_change_below(child, base, layer) {
      return true
    }
  }
  false
}

///|
/// 按层号缩进（两空格一级）。
fn write_indent(builder : StringBuilder, depth : Int32) -> Unit {
  for _ in 0..<depth {
    builder.write_string("  ")
  }
}

///|
/// 单个节点的显示文本。目录带 `/`，链接带目标，可选大小与层号标注。
fn item_text(node : Node, options : RenderOptions) -> String {
  let base = base_name(node.path)
  let suffix = match node.kind {
    NodeKind::Directory => "/"
    NodeKind::Symlink(target) =>
      if options.show_links {
        " -> \{target}"
      } else {
        ""
      }
    NodeKind::Hardlink(target) =>
      if options.show_links {
        " ==> \{target}"
      } else {
        ""
      }
    NodeKind::File => ""
  }
  let mut text = base + suffix
  if options.show_size && node.kind is NodeKind::File && node.size > 0 {
    text = text + " (\{node.size} bytes)"
  }
  if options.show_layer {
    text = text + " [L\{node.layer}]"
  }
  text
}

///|
/// 把 diff 渲染成三个分组，供 CLI 与快照测试使用。
pub fn render_diff(diff : Diff) -> String {
  let builder = StringBuilder()
  builder.write_string(diff.section_name() + "\n")
  write_group(builder, "added", diff.added)
  write_group(builder, "modified", diff.modified)
  write_group(builder, "removed", diff.removed)
  builder.to_string()
}

///|
fn write_group(
  builder : StringBuilder,
  title : String,
  paths : Array[String],
) -> Unit {
  builder.write_string("  \{title}: \{paths.length()}\n")
  for path in paths {
    builder.write_string("    \{path}\n")
  }
}
