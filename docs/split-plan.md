# dive 拆分规划

参考原型：[wagoodman/dive](https://github.com/wagoodman/dive)（Go，MIT，~11.5k 行）。
定位是**参考原型而非移植对象**：dive 依赖 docker/cli、gocui 等整套 Go 生态，MoonBit 侧无等价绑定；
本仓库只吸收它的技术核心——镜像层解析、文件树层叠、体积分析、CI 门禁，并用 MoonBit 重写。

## 拆分总览（按依赖顺序）

| 编号 | 包 | 职责 | 规模估算 | 依赖 |
|---|---|---|---|---|
| P1 | `oci_spec/` | OCI image-spec 类型层：descriptor / manifest / index / config / platform、digest 解析校验、media type 常量、JSON 序列化 | ~1.5k–2.5k 行 | 无（生态空白） |
| P2 | `layer_tree/` | 流式 tar 应用到持久化文件树、`.wh.` / `.wh..wh..plnk` whiteout 语义、层间 diff、路径规范化、树渲染 | ~2.5k–4k 行 | P1 + tar + zstd/gzip |
| P3 | `dive_analysis/` | 跨层重复文件统计、被删文件浪费、cumulative size 排序、efficiency score、JSON/HTML 报告 | ~2k–3k 行 | P2 |
| P4 | `image_ci/` | 体积门禁规则 DSL、阈值判定、exit code 规范、CI 注解输出 | ~1.5k–2.5k 行 | P1 + P3 |

## 为什么这样切

1. **依赖单向**：P1 是纯类型层，无外部依赖，可以立刻开工并快速产出可测的 schema 驱动测试；
   P2/P3/P4 依次依赖前者，不存在循环。
2. **生态去重**：`mizchi/oci_wasm` 只面向 wasm registry 拉取，不做镜像层解析；
   tar / zstd / gzip / sha256 在生态里已有实现，直接复用，不重复造轮子。
   whiteout 语义、层叠 diff、efficiency score、规则 DSL 四处是生态空白，也就是本项目的独立贡献点。
3. **每个包可独立验收**：每个包有自己的 moon.pkg、测试和 CI 门禁，任一包完成都能独立拿初审奖励。

## 统一验收口径

- MoonBit 为主要实现语言，`moon check` / `moon test` 全绿
- 每包有 README、可运行示例、blackbox + whitebox 测试
- 关键路径有测试覆盖（`moon coverage analyze` 兜底）
- 涉及 dive 的思路借鉴处，在文档注明原项目与许可证
- 最终发布到 mooncakes.io

## 里程碑

- M1：P1 完成并发布（类型层 + digest 校验 + 测试）
- M2：P2 完成（whiteout 语义 + 层间 diff）
- M3：P3 完成（efficiency score + 报告输出）
- M4：P4 完成（规则 DSL + CLI），整体打通 `dive <image>` 只读分析链路
