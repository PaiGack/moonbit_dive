# #71：`modified` 的判等口径对齐 dive

## 结论

**对齐原版**（issue 里给的 b + c 两路合并）：判等项取
`(kind, mode, uid, gid)`，与 `dive/filetree/file_info.go` 的 `FileInfo::Compare`
一致；在此之上多一条 **sha256 内容指纹**，补掉原版靠 xxhash 兜住、
而元数据看不到的那一格（同大小、同 mtime、内容不同）。

`size` 也进判等。它不是原版的判等项，但同 kind 下 `size` 变了必然意味着内容变了，
这一条只会与对齐后的口径重合，不会分叉。

`mtime` **不**进判等：原版不看，`COPY` 刷新时间戳不该算改动。

## 为什么不是纯 b（只加哈希）或纯 c（只加 uid/gid）

- 纯 c 认不出「同大小不同内容」，那正是原版靠哈希解决、而 issue 里点名的那一格
- 纯 b（无条件全量哈希）在 20+ 层镜像上就是 20+ 遍全量读取，
  而 `layer_tree` 的立身之本之一是「流式、不把整层解成对象」

折中：**哈希按需**。`apply_layer` / `diff_snapshots` 不读内容；
逐层浏览（`browse_layers` / `browse_decompressed`）默认算一遍，
`content_hashes = false` 可以关掉。所以：

| 入口 | 判等依据 |
|---|---|
| `apply_layer` + `diff_snapshots` | kind / mode / uid / gid / size |
| `browse_*`（默认） | 上面这些 + sha256 指纹 |
| `browse_*(content_hashes=false)` | 上面这些 |
| `FileTree::scan_content` + `diff_snapshots` | 上面这些 + sha256 指纹 |

## 聚合档不改

`diff_aggregate` 仍是「区间里碰过即算」，与原版 `CompareAllLayers` 同口径。
不回看终值内容是有意的：聚合档回答的是「这段区间里这条路径动没动」，
比字节是另一把尺子（`aggregate_size_delta` 管那个）。

## 影响面

- `TarEntry` 多 `uid` / `gid`（tar 头 108 / 116 字节，`parse_octal` 现成）
- `Node` 多 `uid` / `gid` / `digest: Digest?` / `files: Array[NodeFile]`
- `diff_snapshots` 的判等换成 `node_differs`
- `.mbti` 与快照：`browse_*` 的 diff 结果因「同大小不同内容」多出若干 modified
- 依赖 `moonbitlang/x/crypto`（sha256），`oci_spec` 已用过同一份实现

## 用例

`layer_tree/compare_test.mbt` 钉住五种场景：

- 同大小、同 mtime、内容不同 -> `modified`
- 同内容、mtime 不同 -> 不算改动
- 只改 mode -> `modified`
- 只改 uid/gid -> `modified`
- 目录上的属主变化 -> `modified`

外加 `content_scan` 的摘要值与 `Node::files` 的写入流水。
