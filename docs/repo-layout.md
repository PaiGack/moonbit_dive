# 仓库结构与开发约定

单仓库（monorepo）承载四个包，避免多仓库同步成本。

## 结构

```
moon.mod                # PaiGack/dive
moon.pkg                # 根包占位
cmd/main/               # 总 CLI 入口（后续聚合四包能力）
oci_spec/               # P1
layer_tree/             # P2
dive_analysis/          # P3
image_ci/               # P4
docs/                   # 设计文档与拆分规划
```

`cmd/main/` 目前只是 `moon init` 生成的占位入口，等 P1/P2 落地后再接线，不作为可交付功能。

## 开发工作流

- `moon check` 提交前必跑（`.githooks/pre-commit` 已配置）
- `moon test` 全绿才算完成一个包；快照测试用 `moon test --update` 刷新
- `moon info && moon fmt` 更新 `.mbti` 接口与格式，`.mbti` diff 要人工确认
- 每个包一个目录、一个 `moon.pkg`，包间依赖用 `moon add` 声明，不跨目录引用私有实现
- 覆盖率兜底：`moon coverage analyze > uncovered.log`

## 提交与 PR

- 一个 PR 对应一个拆分需求（对应一个子 issue），不把四包塞进同一个 PR
- 提交信息说明「做了什么 + 为什么」，涉及 dive 思路借鉴处注明来源
- 总看板 issue 跟踪四个子 issue 的进度

## 发布

- 每个包独立版本号，达到 M 里程碑后发布到 mooncakes.io
- 根模块版本跟随四个包的整体状态
