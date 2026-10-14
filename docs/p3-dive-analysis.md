# P3 `dive_analysis` — 镜像体积分析与 efficiency score

## 目标

在 P2 的文件树之上做体积分析：找出跨层重复写入、被删除又被浪费的空间，
给出每个路径的 cumulative size，并算一个可比较的 efficiency 分数。

## 范围

### 统计

- 每层新增/修改/删除的字节数与文件数
- 跨层重复文件：同一路径在多层被写、只有最后一次有效
- 被删文件浪费：whiteout 删掉的内容仍占 layer 体积
- cumulative size：某目录子树的总占用，用于热点排序

### efficiency score

- 参考 dive 的加权公式（`filetree/efficiency.go`）：Score = 有效字节 / 总字节，
  其中「有效」= 最后一层仍存在的文件字节
- 分数取值与公式口径写明在 README，避免与 dive 原版产生歧义

### 报告输出

- 稳定可快照的文本报告（层列表 + 体积 + 浪费）
- JSON 报告：结构化字段，供 P4 的门禁判定消费
- 可选 HTML 报告（若时间不够可后置）

## 非目标

- 不做门禁阈值判定（P4 的职责）
- 不做镜像拉取，也不做 Docker Engine 客户端（只吃本地 tar / 已解析的层）
- docker-archive / OCI layout 的输入识别在 P4 的 CLI 层完成

## 验收

- [x] 对少量 fixture 镜像，手工核算的字节数与实现一致
- [x] efficiency score 在「无浪费」「层层覆盖」「删掉大文件」三种极端用例下符合预期
- [x] JSON 报告字段有 schema 文档（[p3-report-schema.md](p3-report-schema.md)）
- [x] 文本报告快照稳定
- [x] `moon check` / `moon test` 全绿

## 落地情况

实现落在 `dive_analysis/`，公开入口：

| 能力 | 入口 |
|---|---|
| 逐层体积核算 | `analyze_layers`、`Analysis`、`LayerUsage` |
| 路径体积账 | `Analysis::path_size`、`PathSize`、`Analysis::waste_ranking` |
| efficiency score | `Analysis::efficiency`、`EfficiencyReport`、`efficiency_of_versions` |
| 目录热点 | `hotspots`、`Hotspot` |
| 报告 | `build_report`、`render_text_report`、`report_to_json`、`report_to_json_string` |

**efficiency score 的口径**：与 dive `dive/filetree/efficiency.go` 一致，按**路径**
跨所有层聚合，`score = Σ min_discovered / Σ cumulative`。因此「同一路径写两次、
大小相同」会掉到 0.5；被 whiteout 删掉的路径以 `0` 参与 min 计算。
这个口径与「浪费字节占比」不同，报告里两个数字都给，含义见包内 README。

**实现取舍**：分析会重新扫一遍每层 tar（`scan_layer`），而不是读最终树——
被 whiteout 删掉的内容已经不在树上，但它们在镜像里真实占着空间，必须逐层记账。
扫描先列清单、再让 P2 的 `apply_layer` 改树，否则旧值在落树后查不到。

## 可选项未做

- HTML 报告按计划后置（时间不足），不在本次范围内

## 参考

- dive 的 `dive/filetree/efficiency.go`、`dive/image/analysis.go`（MIT）
