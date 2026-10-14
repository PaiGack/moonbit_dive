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

- [ ] 对少量 fixture 镜像，手工核算的字节数与实现一致
- [ ] efficiency score 在「无浪费」「层层覆盖」「删掉大文件」三种极端用例下符合预期
- [ ] JSON 报告字段有 schema 文档
- [ ] 文本报告快照稳定
- [ ] `moon check` / `moon test` 全绿

## 参考

- dive 的 `dive/filetree/efficiency.go`、`dive/image/analysis.go`（MIT）
