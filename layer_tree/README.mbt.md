# layer_tree

把 OCI 镜像的每一层 tar 依次应用到一个文件树上，正确处理 **whiteout** 语义，
并给出相邻层之间的 diff。这是 [dive](https://github.com/wagoodman/dive)（Go，MIT）技术核心
在 MoonBit 上的实现。

包内自带 tar 解析与 DEFLATE/gzip 解压，不依赖外部压缩库。

## 快速开始

```moonbit check
///|
test "README example" {
  // 手工造两层 tar（真实场景下数据来自镜像 registry）
  let layer0 = @layer_tree.build_tar([
    @layer_tree.Dir("etc"),
    @layer_tree.File("etc/hosts", "127.0.0.1 localhost"),
    @layer_tree.File("etc/passwd", "root:x:0:0"),
  ])
  let layer1 = @layer_tree.build_tar([
    // 第三层把 passwd 删掉，并改写 hosts
    @layer_tree.Whiteout("etc", "passwd"),
    @layer_tree.File("etc/hosts", "127.0.0.1 localhost\n::1 localhost"),
  ])

  let result = @layer_tree.apply_layers_with_diffs([layer0, layer1]) catch {
    err => fail(err.to_string())
  }

  // 最终树：passwd 已消失，hosts 被覆盖
  assert_true(result.tree.get("/etc/passwd") is None)
  inspect(
    @layer_tree.render_tree(result.tree),
    content=(
      #|/
      #|  etc/ [L0]
      #|    hosts (33 bytes) [L1]
      #|
    ),
  )

  // 第 1 层的 diff
  let diff = result.diffs[1]
  assert_eq(diff.removed, ["/etc/passwd"])
  assert_eq(diff.modified, ["/etc/hosts"])
}
```

## 能力

| 能力 | 入口 |
|---|---|
| 文件树模型 | `FileTree`、`Node`、`NodeKind` |
| 路径规范化 | `normalize_path`、`join_path`、`path_is_under`、`path_order` |
| tar 解析（流式） | `TarReader`、`parse_tar_entries`、`read_file_from_tar` |
| 压解压 | `gzip_decompress`、`inflate`、`crc32`、`decompress_layer` |
| 层应用 | `apply_layer`、`apply_layer_with_media_type`、`apply_layers_with_diffs` |
| whiteout | `whiteout_kind`、`WhiteoutKind`、`remove_subtree`、`make_opaque` |
| 层间 diff | `diff_snapshots`、`diff_against_empty`、`Diff` |
| 树渲染 | `render_tree`、`render_tree_between`、`render_diff` |

## whiteout 语义

OCI / AUFS 用特殊文件名表达「删除」，它们本身不会出现在最终文件树里：

| 条目 | 语义 |
|---|---|
| `.wh.<name>` | 删除同目录下名为 `<name>` 的条目（目录则整棵子树） |
| `.wh..wh..opq` | 该目录变成 opaque：旧内容整体让位给本层写入 |
| `.wh..wh..plnk` | 硬链接维护文件，识别但不影响树 |

`.wh.` 只在路径最后一段生效——`etc/.wh.nested/file` 里的 `.wh.nested` 是普通目录名。

层之间是**时间序**而不是集合差：同一路径被 whiteout 后又写回同名文件，
在 diff 里表现为 `modified`（路径两层都存在，内容变了），
只有真正消失的路径才进 `removed`。

## 设计要点

- **流式处理**：`TarReader` 逐条读 entry，不把整层解成对象；数据只在需要时按偏移取。
  `tar_block_size` 是唯一的对齐常量。
- **路径即真相**：树节点比的是 `parent` + `insert_child`，不按 tar 里的顺序堆叠；
  重写同一路径就地更新，不复制节点。
- **自实现 gzip**：MoonBit 生态暂无 DEFLATE，包里补了一个（crc32 + Huffman + stored block）。
  支持 fixed/dynamic Huffman 与 stored 三种块类型，zstd 明确报 `Unsupported` 而不是静默跳过。

## 许可与出处

- whiteout 与层间 diff 的思路来自 dive 的 `dive/filetree/`（MIT）
- whiteout 语义定义见 [OCI image-spec layer.md](https://github.com/opencontainers/image-spec/blob/main/layer.md#whiteouts)（Apache-2.0）
