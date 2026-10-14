# P4 `image_ci` — 镜像体积门禁规则 DSL 与 CLI

## 目标

把 P3 的分析结果变成 CI 里能用的门禁：声明式规则 + 明确 exit code + CI 注解输出，
让「镜像胖了就把流水线卡住」这件事可配置、可解释。

## 范围

### 规则 DSL

参考 dive `ci/rules.go` 的形态，但用 MoonBit 数据结构表达（不引入 yaml 依赖的话，
先支持从 JSON / 配置结构构造）。规则示例：

- 总镜像大小上限（绝对字节 / MB）
- 单层大小上限
- 浪费空间（wasted bytes）上限
- efficiency score 下限
- 路径白名单/黑名单（例如禁止把 `node_modules` 打进镜像）
- 单文件大小上限

### 判定与输出

- 每条规则给出 pass / fail 与失败原因
- 汇总结果输出到 stdout（人类可读 + JSON 两种）
- exit code 规范：0 全过，非 0 表示有规则失败并区分「规则本身错误」与「规则未通过」
- CI 注解：输出可被 CI 解析的标注（如 `::error::` 形式）

### CLI 接线

- `cmd/main` 聚合 P1→P2→P3→P4：`dive <image.tar> --rules rules.json`
- 只读分析链路先打通，不要求交互界面

## 非目标

- 不做交互式 TUI（dive 的 gocui 部分不复刻）
- 不做 registry 拉取

## 验收

- [ ] 至少覆盖上列 6 类规则，每条有独立测试
- [ ] exit code 在「全过 / 有失败 / 规则非法」三种情况下区分正确
- [ ] JSON 输出有 schema 文档，能直接被 CI 消费
- [ ] 用真实（或构造的）镜像走一遍端到端，README 记录命令与预期结果
- [ ] `moon check` / `moon test` 全绿

## 参考

- dive 的 `cmd/dive/cli/internal/ci/`（MIT）
