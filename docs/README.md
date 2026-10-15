# 文档索引

本目录存放 `dive` 的设计与拆分规划文档。实现进度以看板 issue 为准。

| 文档 | 内容 |
|---|---|
| [split-plan.md](split-plan.md) | 五个拆分包的总体规划、依赖顺序、生态去重与验收口径 |
| [p1-oci-spec.md](p1-oci-spec.md) | P1 `oci_spec`：OCI image-spec 类型层 |
| [p2-layer-tree.md](p2-layer-tree.md) | P2 `layer_tree`：tar 层叠文件树 + whiteout diff |
| [p3-image-analysis.md](p3-image-analysis.md) | P3 `image_analysis`：体积分析与 efficiency score |
| [p3-report-schema.md](p3-report-schema.md) | P3 JSON 报告 schema（供 P4 门禁消费） |
| [p4-image-ci.md](p4-image-ci.md) | P4 `image_ci`：镜像体积门禁规则 DSL 与 CLI |
| [p4-rules-schema.md](p4-rules-schema.md) | P4 门禁输入（rules.json）与输出（判定结论 / 注解）的 JSON schema |
| [p5-docker-cli.md](p5-docker-cli.md) | P5 `docker_cli`：CLI / Engine 双后端、探测降级、与 P2/P3 的接线 |
| [docker-cli-survey.md](docker-cli-survey.md) | docker cli 封装的生态调研、范围取舍（结论已按 P5 issue #17 修订）、P2 的 tar 坑 |
| [p6-tui.md](p6-tui.md) | P6 `tui`：交互式看树（基于 `moonbit-community/tty`，路径 A） |
| [repo-layout.md](repo-layout.md) | 仓库结构、开发工作流、提交与发布约定 |
