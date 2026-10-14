# 文档索引

本目录存放 `dive` 的设计与拆分规划文档。实现进度以看板 issue 为准。

| 文档 | 内容 |
|---|---|
| [split-plan.md](split-plan.md) | 四个拆分包的总体规划、依赖顺序、生态去重与验收口径 |
| [docker-cli-survey.md](docker-cli-survey.md) | 要不要做 docker cli：MoonBit 生态调研、输入接口取舍、P2 的 tar 坑 |
| [p1-oci-spec.md](p1-oci-spec.md) | P1 `oci_spec`：OCI image-spec 类型层 |
| [p2-layer-tree.md](p2-layer-tree.md) | P2 `layer_tree`：tar 层叠文件树 + whiteout diff |
| [p3-dive-analysis.md](p3-dive-analysis.md) | P3 `dive_analysis`：体积分析与 efficiency score |
| [p4-image-ci.md](p4-image-ci.md) | P4 `image_ci`：镜像体积门禁规则 DSL 与 CLI |
| [repo-layout.md](repo-layout.md) | 仓库结构、开发工作流、提交与发布约定 |
