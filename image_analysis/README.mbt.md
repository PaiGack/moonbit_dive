# image_analysis

在 P2 的层叠文件树之上做**镜像体积分析**：找出跨层重复写入、被 whiteout 删掉的浪费，
给出每个路径的 cumulative size 与一个可比较的 efficiency 分数。

这是 [dive](https://github.com/wagoodman/dive)（Go，MIT）`filetree/efficiency.go`
与 `image/analysis.go` 的技术核心在 MoonBit 上的实现。

## 快速开始

```moonbit check
///|
test "README example" {
  // 手工造两层 tar（真实场景下数据来自镜像 registry）
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
  ])

  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = [layer0, layer1]
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }

  // 前一个版本的 10 字节被后一层覆盖，算作浪费
  assert_eq(analysis.final_file_bytes, 16)
  assert_eq(analysis.overwritten_wasted, 10)
  assert_eq(analysis.wasted_bytes(), 10)

  let report = @image_analysis.build_report(analysis, tree)
  // 分数按路径取 min：min=10 / cumulative=26
  assert_eq(report.efficiency.min_bytes, 10)
  assert_eq(report.efficiency.cumulative_bytes, 26)
  assert_true(report.efficiency.score() < 0.4)
}
```

## 能力

| 能力 | 入口 |
|---|---|
| 逐层体积核算 | `analyze_layers`、`analyze_decompressed`、`Analysis`、`LayerUsage` |
| 路径体积账 | `Analysis::path_size`、`PathSize`、`Analysis::waste_ranking` |
| efficiency score | `Analysis::efficiency`、`EfficiencyReport`、`efficiency_of_versions` |
| 逐路径效率表 | `efficiency_view_rows`、`EfficiencyViewOptions`、`render_efficiency_view`、`efficiency_view_to_json` |
| 目录热点 | `hotspots`、`Hotspot` |
| 报告 | `build_report`、`render_text_report`、`report_to_json`、`report_to_json_string`、`report_to_html` |

## efficiency score 口径

**严格对齐 dive**（`dive/filetree/efficiency.go`），按**路径**聚合、跨所有层：

- `cumulative` = 该路径在所有层被写过的字节数之和
- `min_discovered` = 这些版本里最小的那个字节数
- `score = Σ min_discovered / Σ cumulative`，值域 `[0, 1]`

推论（也是我们测试里钉住的用例）：

- 同一路径写两次、大小相同 → 分数从 1.0 掉到 0.5（空间确实被占了两份）
- 先写 10 字节、再写 100 字节 → min=10、cumulative=110，分数崩到 0.09
- 被 whiteout 删掉的路径：版本序列以 `0` 收尾，min 记 0，原大小早已计入 cumulative
- 「先删后加同名文件」会同时计两次写入，符合 OCI 的层语义
- `cumulative == 0`（空镜像 / 全是空文件 / 纯目录层）时定义为 `1.0`，避免除零

分数与「浪费字节占比」**不是一回事**：前者按路径取 min，重复写同样大小的内容不扣分，
后者是 `wasted / written`。报告里两个数字都给出来，别混用。

## 逐路径效率表

分数只告诉你「低了」，不告诉你「是哪条路径拖的」。要回答后者，
用 `efficiency_view_rows` 从 `EfficiencyReport.paths` 里挑出那张表：

```moonbit check
///|
test "README efficiency view example" {
  // 一个路径被放大重写、另一个同大小重写：两者的「多写」量完全不同
  let report = @image_analysis.efficiency_of_versions({
    "/app/main.js": [10, 20],
    "/app/util.js": [8, 8],
  })
  let view = @image_analysis.EfficiencyViewOptions::new(top=10)
  let rows = @image_analysis.efficiency_view_rows(report, view)
  // 先写 10 再写 20：多写的是后一份多出来的 20 字节
  assert_eq(rows[0].path, "/app/main.js")
  assert_eq(rows[0].cumulative_bytes, 30)
  assert_eq(rows[0].min_bytes, 10)
  assert_eq(rows[0].size, 20)
  // 同大小重写：空间占了 2 份，但「多写的」仍然等于单份大小
  assert_eq(rows[1].path, "/app/util.js")
  assert_eq(rows[1].size, 8)
}
```

口径就是 `cumulative - min`（多写了几份），与 efficiency 总分的分子分母同源：
表里每行的 `cumulative_bytes` 加起来等于 `report.efficiency.cumulative_bytes`，
所以随便取一行都能反推总分。排序沿用 `EfficiencyReport.paths` 的顺序
（waste 降序、同分按 `path_order`）。

**它不等于 `wasteful_paths` 的 `wasted_bytes`**：

| 场景 | `wasted_bytes`（覆盖 + 删除的实际字节） | `size`（`cumulative - min`） |
|---|---|---|
| 10 字节写成 10 字节 | 10 | 10 |
| 10 字节被 100 字节覆盖 | 10 | 90 |
| 100 字节被 1 字节覆盖 | 100 | 1 |
| 被 whiteout 删掉 | 原大小 | 原大小（min 取 0） |

两个榜各自的读者不同：前者回答「空间实际丢在哪」，后者回答「是谁把分数拉下来的」。
两套数字不混在一张表里，也不互相换算。

`EfficiencyViewOptions` 的两个开关：`path` 做前缀过滤（`/app/` 与 `/app` 等价），
`top` 限条数（负数不截断，CLI 的 `--top 0` 翻成它）。**先过滤再截断**——
「只看 /app 下的前 20 条」是先挑再取，反过来会少出一半。

## 报告字段

文本报告（`render_text_report`）逐行固定格式，可整份快照：

```
layers: 3
  L0: +3 ~0 -0 paths, wrote 15 bytes, wasted 0 bytes
  ...
image:
  current: 16 bytes in 2 paths
  written: 31 bytes
  wasted: 15 bytes (48.4%)
efficiency: 32.3% (10/31)
```

JSON 报告（`report_to_json_string`）的结构见 [docs/p3-report-schema.md](../docs/p3-report-schema.md)，
带 `schemaVersion` 字段，供 P4 的门禁判定消费。

逐路径效率表（`render_efficiency_view` / `efficiency_view_to_json`）是**另一种视图**，
不是整份报告的一部分，结构版本号也独立（`efficiency_view_schema_version`）：

```
efficiency: 32.1% (18/56)
paths by extra writes (cumulative - min), scope: /, showing 3:
  20 bytes  cumulative 30  min 10  x2  /app/main.js
  10 bytes  cumulative 10  min 0  x2  /lib/a
  8 bytes  cumulative 16  min 8  x2  /app/util.js
```

两张表（`wasteful paths` 与这张）在 CLI 里是互斥的开关，不会同时出现。

HTML 报告（`report_to_html`）是同一份 `Report` 的第三个渲染后端：单文件、无外部依赖、
内联样式，顶部概览卡 + 逐层表 + efficiency 进度条 + 浪费 / 热点两张表。所有路径名都过
`html_escape`，`<` `&` 引号不会撑破结构。CLI 用法：

```bash
dive image.tar --format html -o report.html
```

## 设计要点

- **逐层扫 tar 而不是读最终树**：被 whiteout 删掉的内容已经不在树上，但它们在镜像里
  真实占着空间。分析因此把每层 tar 再扫一遍，边扫边记账。
- **吃已解压的层**：`analyze_decompressed` 收 `layer_tree::DecompressedLayers`，
  与逐层视图共用同一批 tar 字节。要同时出「每层快照」和「跨层统计」的调用方
  （例如 TUI）只需解压一遍（issue #52）；`analyze_layers` 仍然收原始字节，
  内部先解压，单独用的场景不受影响。
- **先列清单再落树**：`scan_layer` 先把「这一层会写什么、删什么」列清楚，
  再让 P2 的 `apply_layer` 改树。否则旧值会在落树后消失，浪费算不出来。
- **一份中间结构**：文本与 JSON 都从 `Report` 出，避免两套口径各算一套数字。

## 许可与出处

- efficiency 公式与「重复写入扣分」的思路来自 dive 的 `dive/filetree/efficiency.go`（MIT）
- whiteout / opaque 的语义定义见 [OCI image-spec layer.md](https://github.com/opencontainers/image-spec/blob/main/layer.md#whiteouts)（Apache-2.0）
