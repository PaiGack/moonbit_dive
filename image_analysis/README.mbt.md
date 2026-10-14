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
| 逐层体积核算 | `analyze_layers`、`Analysis`、`LayerUsage` |
| 路径体积账 | `Analysis::path_size`、`PathSize`、`Analysis::waste_ranking` |
| efficiency score | `Analysis::efficiency`、`EfficiencyReport`、`efficiency_of_versions` |
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

HTML 报告（`report_to_html`）是同一份 `Report` 的第三个渲染后端：单文件、无外部依赖、
内联样式，顶部概览卡 + 逐层表 + efficiency 进度条 + 浪费 / 热点两张表。所有路径名都过
`html_escape`，`<` `&` 引号不会撑破结构。CLI 用法：

```bash
dive image.tar --format html -o report.html
```

## 设计要点

- **逐层扫 tar 而不是读最终树**：被 whiteout 删掉的内容已经不在树上，但它们在镜像里
  真实占着空间。分析因此把每层 tar 再扫一遍，边扫边记账。
- **先列清单再落树**：`scan_layer` 先把「这一层会写什么、删什么」列清楚，
  再让 P2 的 `apply_layer` 改树。否则旧值会在落树后消失，浪费算不出来。
- **一份中间结构**：文本与 JSON 都从 `Report` 出，避免两套口径各算一套数字。

## 许可与出处

- efficiency 公式与「重复写入扣分」的思路来自 dive 的 `dive/filetree/efficiency.go`（MIT）
- whiteout / opaque 的语义定义见 [OCI image-spec layer.md](https://github.com/opencontainers/image-spec/blob/main/layer.md#whiteouts)（Apache-2.0）
