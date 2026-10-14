# P3 `dive_analysis` — 镜像体积分析与 efficiency score

## 目标

回答 dive 的核心问题：「这个镜像的体积浪费在哪？效率多少分？」

## 范围

### 统计维度

- **跨层重复文件**：同一路径在多处被写入，只保留最后一次，其余记为浪费
- **被删文件**：某层写入、后续层 whiteout 删除，体积计为浪费
- **cumulative size**：按层累计，定位「从第几层开始体积暴涨」
- **文件类型分布**：按扩展名/顶层目录聚合，找出体积大头

### efficiency score

复刻 dive 的加权公式：`efficiency = (sum(fileSizes) - wastedBytes) / sum(fileSizes)`，
其中 wastedBytes 含重复文件与被删文件。给出百分比与分级（如 >=0.95 为优秀）。

### 报告输出

- JSON：机器可读，含每层文件数、字节数、重复清单、删除清单
- HTML：单文件自包含报告，一张层叠条形图 + top-N 浪费文件表（不引入前端依赖，内联 SVG/CSS）
- 终端文本：`dive` 风格的人类可读摘要

## 依赖

- P2 `layer_tree`（提供树与 diff）
- P1 `oci_spec`（提供 descriptor 的 size/digest，用于交叉校验）

## 非目标

- 不做交互式 TUI（那是壳，且生态有 `mizchi/tui`；先把库做扎实）

## 验收

- [ ] 对一个已知浪费的镜像（可构造：故意多写大文件再删），报告出的 wastedBytes 与手工核算一致
- [ ] efficiency 分数对「无浪费镜像」为 1.0（边界测试）
- [ ] JSON schema 稳定，有快照测试
- [ ] HTML 报告可在浏览器直接打开，无外链资源
- [ ] `moon check` / `moon test` 全绿

## 参考

- dive `dive/filetree/efficiency.go`、`dive/image/analysis.go`
