# P4 `image_ci` — 镜像体积门禁规则 DSL 与 CLI

## 目标

把「CI 里检查镜像是否超标」做成开箱即用的 MoonBit 包：一条命令、一份规则、一个 exit code。

## 范围

### 规则 DSL

参考 dive `dive/dive/image/../../cmd/dive/cli/ci/rules.go`（约 196 行 Go）的思路，用 MoonBit 实现：

```yaml
rules:
  - lowestEfficiency: 0.95
  - highestBytes: 500MB
  - highestUserFileCount: 1000
  - wastedBytes:
      threshold: 50MB
      filePattern: "*.log"
```

- 规则项：`lowestEfficiency`、`highestBytes`、`highestUserFileCount`、`wastedBytes`（带 filePattern）
- 组合逻辑：任一规则命中即失败，全部通过才 exit 0

### 阈值单位

支持 `B` / `KB` / `MB` / `GB` / `KiB` / `MiB` / `GiB`，与 dive 的单位口径一致。

### CLI 行为

- `image-ci check <image.tar> --rules rules.yaml`（先支持 `docker save` 出的 tar，不依赖 daemon）
- exit code：0 通过 / 1 规则失败 / 2 用法或加载错误（与 dive CI 对齐）
- 失败时输出命中的规则、实际值、阈值，以及 GitHub Actions 注解格式（`::error file=...,line=...::`）

### 解析

- YAML 规则文件解析（找生态现成 YAML 包，没有则先支持 JSON 等价物）
- 规则文件 schema 校验，错误信息指出具体行号

## 依赖

- P1 `oci_spec`、P3 `dive_analysis`

## 验收

- [ ] 四类规则各有一个通过用例和一个失败用例
- [ ] exit code 符合规范，CI 脚本可直接依赖
- [ ] 单位解析边界（大小写、无空格、`1e3` 之类的非法写法）有明确报错
- [ ] README 给出 GitHub Actions / Gitlink CI 的接入片段
- [ ] `moon check` / `moon test` 全绿

## 参考

- dive `cmd/dive/cli/ci/rules.go`
