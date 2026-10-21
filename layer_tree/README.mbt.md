# layer_tree

把 OCI 镜像的每一层 tar 依次应用到一个文件树上，正确处理 **whiteout** 语义，
并给出相邻层之间的 diff。这是 [dive](https://github.com/wagoodman/dive)（Go，MIT）技术核心
在 MoonBit 上的实现。

包内自带 tar 解析与 DEFLATE/gzip 解压，不依赖外部压缩库。

## 快速开始

```moonbit check
///|
async test "README example" {
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
| 层间 diff | `diff_snapshots`、`diff_against_empty`、`diff_aggregate`、`Diff` |
| 逐层浏览 | `browse_layers`、`browse_decompressed`、`LayerView`、`LayerView::subtree`、`LayerView::changed_paths`、`LayerView::aggregate_changed_paths` |
| 解压一次多路复用 | `decompress_layers`、`DecompressedLayers` |
| 树渲染 | `render_tree`、`render_tree_between`、`render_diff` |

## 判等口径

**这一条与原版的取舍在 issue #71 里拍过：对齐。**

`modified` 怎么算，直接对齐原版 dive 的 `FileInfo::Compare`：

```go
// dive/filetree/file_info.go
if data.TypeFlag == other.TypeFlag {
    if data.hash == other.hash && data.Mode == other.Mode &&
       data.Uid == other.Uid && data.Gid == other.Gid {
        return Unmodified
    }
}
return Modified
```

也就是 **`(kind, mode, uid, gid)` 全等才算没动过**。本仓在这之上多一条内容指纹，
补掉原版靠内容哈希兜住、而元数据看不到的那一格：

| 变化 | 原版 | 本仓 |
|---|---|---|
| 内容不同、`size` 也不同 | `Modified` | `Modified`（`size` 变了） |
| 内容不同、`size` 相同、`mtime` 相同 | `Modified`（比哈希） | `Modified`（比 sha256 指纹） |
| 内容相同、`mtime` 不同（`COPY` 刷新时间戳） | `Unmodified` | `Unmodified`（不看 `mtime`） |
| `chmod` / `chown` | `Modified` | `Modified` |

`size` 进判等是因为它由 kind 与内容决定，原版虽然不显式看它，但同 kind 下 `size` 变了
必然意味着内容变了，因此这一条不会与对齐后的口径分叉。

### 与原版的两点已知差别

- **哈希算法**：原版是 xxhash 64 位，本仓是 sha256（复用 `moonbitlang/x/crypto`）。
  两者都只用来判断「内容一样吗」，不会影响任何结论，只是本仓算得慢一点、强一点。
- **算不算哈希**：原版在解析 tar 头时无条件把每个文件读一遍；本仓默认只在
  逐层浏览（`browse_*`）时算，`FileTree::scan_content` 是显式入口。
  只做 `apply_layer` + `diff_snapshots` 的话不读内容，代价是「同大小不同内容」认不出来。

### 内容指纹是「按需」的

`Node::digest` 与 `Node::files` 默认是空的：逐层叠树时不读文件内容
（大镜像上这就是实打实的一遍全量读取）。需要内容级精度时显式跑一次：

```mbt check
///|
async test "README content hashes" {
  let layer0 = build_tar([TarEntrySpec::File("app/main.js", "0123456789")])
  let layer1 = build_tar([TarEntrySpec::File("app/main.js", "abcdefghij")])
  // 显式入口：`scan_content` 之后节点上才有内容摘要
  let tree = FileTree::new()
  apply_layer(tree, layer0, 0) catch {
    err => fail(err.to_string())
  }
  assert_true(tree.require("/app/main.js").digest is None)
  tree.scan_content([layer0])
  assert_eq(
    tree.require("/app/main.js").digest.unwrap().hash,
    Some("84d89877f0d4041efb6bf91a16f0248f2fd573e6af05c19f96bedb9f882f7882"),
  )
  // 逐层浏览默认也会按 tar 算一遍：这一档因此认得
  // 「同大小、同 mtime、内容不同」，不必自己调 scan_content
  let views = browse_layers([layer0, layer1]) catch {
    err => fail(err.to_string())
  }
  assert_eq(views[1].diff.modified, ["/app/main.js"])
}
```

`browse_decompressed` 的 `content_hashes = false` 可以关掉这一步，
代价是逐层档退回「只比元数据 + `size`」，「同大小不同内容」认不出来。

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

## 逐层浏览

`browse_layers` 把「每层应用完之后树长什么样」抽出来：返回的 `LayerView` 数组与层一一对应，
每个视图带该层的快照与相对上一层的 diff。CLI 的 `--layer` / `--path` 就是它的只读替身
（没有 TUI 的交互，但能一次看一层）。

```mbt check
///|
async test "README layer browse" {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "v1"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "v2-longer"),
  ])
  let views = @layer_tree.browse_layers([layer0, layer1]) catch {
    err => fail(err.to_string())
  }
  // 第 0 层的树只有旧内容
  assert_eq(views[0].tree.require("/app/main.js").info.size, 2)
  // 第 1 层是覆盖，diff 里表现为 modified
  assert_eq(views[1].diff.modified, ["/app/main.js"])
  assert_eq(views[1].changed_paths(), ["/app/main.js"])
  // 按目录下钻：沿途祖先目录保留，供缩进参照
  let app = views[1].subtree("/app")
  assert_eq(app.size(), 2)
  inspect(
    @layer_tree.render_tree(app),
    content=(
      #|/
      #|  app/ [L0]
      #|    main.js (9 bytes) [L1]
      #|
    ),
  )
}
```

## 解压一次，两条链路共用

逐层浏览与跨层体积分析吃的是同一批层。让两条链路各自解压一遍，在大镜像上就是
白多花一次解压的时间、峰值内存也翻倍（issue #52）。所以解压单独抽一步：

```mbt check
///|
async test "README decompress once" {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "v1"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "v2"),
  ])
  let layers : Array[BytesView] = [layer0, layer1]
  // 解压一遍：`decompressed` 记录的就是解压次数（等于层数）
  let decompressed = @layer_tree.decompress_layers(layers) catch {
    err => fail(err.to_string())
  }
  assert_eq(decompressed.decompressed, 2)
  // 逐层视图从这里出，不再碰原始字节
  let views = @layer_tree.browse_decompressed(decompressed)
  assert_eq(views.length(), 2)
}
```

`browse_layers` / `analyze_layers` 这些收原始字节的入口都保留，
它们内部就是「先 `decompress_layers` 再走已解压入口」，语义完全一致。

## 两个比较档位：当前层 vs 聚合

`LayerView` 带两份 diff，对应原版 dive（Go）layer 面板的 `Ctrl+L` / `Ctrl+A`：

| 字段 | 比较区间 | 看到的是什么 |
|---|---|---|
| `diff` | `[n-1, n]` | 这一层相对上一层改了什么 |
| `aggregate` | `[第 0 层之前, n]` | 从 `L0` 到现在这一整段累积改了什么 |

**换的是比较区间，不是数据源**：树只有一棵（`LayerView.tree`），切档位只换给行上色的那份 diff。

判等口径对齐后，聚合档多了一层要求：区间端点上字节一样不算「没动过」，
**这段区间里被碰过**才算数。所以它不是「拿两棵树做一次 `diff_snapshots`」，
而是按区间**累积**：

- 取区间内各层 diff 里被碰过的全部路径
- 按两端的树归类：只在终点 -> `added`，两头都在 -> `modified`，只在起点 -> `removed`
- 区间内碰过、最后两头都不在的路径丢掉（视图画的是终点的树，没有行可以落）
- 没被直接碰过、但子树里有改动的目录并入 `modified`
  （对齐 dive 的 `deriveDiffType`：父目录合并子节点的 diff）

**「碰过即算」是刻意的，不改。** 聚合档回答的是「这层树上有哪些行是这段区间里
动过的」，不是「两端字节差了几处」——后者直接比两个端点就行，不需要聚合。
所以「第 0 层写过、第 1 层改成别的、第 2 层又改回原样」的路径在聚合档里仍是
`modified`，与原版 dive 的 `CompareAllLayers` 一致；
上面那条内容指纹只服务逐层档，不参与聚合。

被删的路径不在终点的树上，所以 `aggregate.removed` 是「删除」唯一的出口：
CLI 的 `--aggregate` 单列一段，TUI 用 `d` 打开一张可滚动的列表。

```mbt check
///|
async test "README aggregate compare" {
  let l0 = build_tar([Dir("app"), File("app/main", "v1")])
  let l1 = build_tar([File("app/main", "v2-longer")])
  // 第 2 层改回与第 0 层一模一样的字节
  let l2 = build_tar([File("app/main", "v1")])
  let views = browse_layers([l0, l1, l2]) catch { err => fail(err.to_string()) }
  // 逐层档：第 2 层相对第 1 层动了这条路径
  assert_eq(views[2].diff.modified, ["/app/main"])
  // 聚合档：与第 0 层比字节一样，但这段区间里碰过，仍算 modified
  assert_eq(views[2].aggregate.modified, ["/app", "/app/main"])
  assert_eq(views[2].aggregate.removed, [])
  // 区间起点是第 0 层的树，体积差就是「从第 0 层到现在涨了多少」
  assert_eq(views[2].aggregate_size_delta(0), 0)
}
```

`aggregate_size_delta(base)` 是**端点差**（终点的树减去起点的树），
与聚合 diff 的「碰过即算」不是同一把尺子：被改回原样的路径在 diff 里是 `modified`，
在体积差里贡献 0。两个数各有各的用处，别互相印证。

## 设计要点

- **流式处理**：`TarReader` 逐条读 entry，不把整层解成对象；数据只在需要时按偏移取。
  `tar_block_size` 是唯一的对齐常量。
- **路径即真相**：树节点比的是 `parent` + `insert_child`，不按 tar 里的顺序堆叠，
  tar 里谁先谁后不影响结果。
- **节点不可变**：`Node` 没有 `mut` 字段，元数据收在 `NodeInfo` 里。
  覆写一条路径 = 换一个新 `Node` 顶掉 `nodes` 里的那一项，`children` 逐层换成新数组
  （`FileTree::relink_parent` 一路换到根）。代价是每次写入会重建父链上的数组，
  换来的是 `snapshot` 可以**按路径共享**：没动过的节点不复制，
  「先快照、再叠层」也不会把旧快照改到脚底下（issue #122 第 5 项）。
- **自实现 gzip**：MoonBit 生态暂无 DEFLATE，包里补了一个（crc32 + Huffman + stored block）。
  支持 fixed/dynamic Huffman 与 stored 三种块类型。
- **zstd 用 `gaato/zstd`**：纯 MoonBit、流式、只做解码，`decompress` 直接吃 `BytesView`，
  与 `gzip_decompress` 同一个形状，所以 `decompress_layer` / `decompress_layers` /
  `apply_layer_with_media_type` 这三条路径不用为 zstd 开第二套语句。
  错误按 `ZstdErrorKind` 翻成可断言的文案（`DecompressError::Zstd`）。
- **层的压缩方式只从 media type 推**（`compression_of`）；认不出来就当未压缩。
  不认识的算法（`lz4` 之类）在 `decompress_layer` 上明确报 `Unsupported`，
  不会被当成未压缩送进 tar 解析器。

## 许可与出处

- whiteout 与层间 diff 的思路来自 dive 的 `dive/filetree/`（MIT）
- whiteout 语义定义见 [OCI image-spec layer.md](https://github.com/opencontainers/image-spec/blob/main/layer.md#whiteouts)（Apache-2.0）
