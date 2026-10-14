# 仓库结构与开发约定

单仓库（monorepo）承载五个包（P5 独立于 P1–P4），避免多仓库同步成本。

## 结构

```
moon.mod                # PaiGack/dive
moon.pkg                # 根包占位
cmd/main/               # 总 CLI 入口（后续聚合四包能力）
oci_spec/               # P1
layer_tree/             # P2
dive_analysis/          # P3
image_ci/               # P4
docker_cli/             # P5（独立包，不被 P1–P4 依赖）
docs/                   # 设计文档与拆分规划
```

`cmd/main/` 是只读分析链路的入口，已接上 P1→P2→P3→P4：
`dive <image.tar|layout-dir|-> [--rules rules.json] [--format text|json|annotations]`。
它只做接线，判定逻辑都在 `image_ci` 里。

另有一支「逐层浏览」入口，是 dive 交互界面的只读替身：
`dive <image> --layer N [--path P]`。给了 `--layer` / `--path` 就不做门禁判定，
只打印那一层的文件树与该层 diff；`--path` 按目录下钻，纯给 shell 用，
不做 TUI（gocui 那部分不在范围内）。实现落在 `layer_tree::browse_layers`。

P5 `docker_cli` 已按同样约定落地（`moon.pkg` + README + 测试），见 [issue #17](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/17)。
它是唯一带平台约束的包：进程与 unix socket 只在 native / wasm 后端可用，
`.cnb.yml` / 本地跑测试时用 `--target wasm`。

## 开发工作流

- `moon check` 提交前必跑（`.githooks/pre-commit` 已配置）
- `docker_cli` 的测试要显式指 target：`moon test -p docker_cli --target wasm`
- `moon test` 全绿才算完成一个包；快照测试用 `moon test --update` 刷新
- `moon info && moon fmt` 更新 `.mbti` 接口与格式，`.mbti` diff 要人工确认
- 每个包一个目录、一个 `moon.pkg`，包间依赖用 `moon add` 声明，不跨目录引用私有实现
- 覆盖率兜底：`moon coverage analyze > uncovered.log`

## 提交与 PR

- 一个 PR 对应一个拆分需求（对应一个子 issue），不把四包塞进同一个 PR
- 提交信息说明「做了什么 + 为什么」，涉及 dive 思路借鉴处注明来源
- 看板 issue 跟踪四个子 issue 的进度

## 发布

- 每个包独立版本号，达到 M 里程碑后发布到 mooncakes.io
- 根模块版本跟随四个包的整体状态
