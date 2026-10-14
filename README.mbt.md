# dive

MoonBit 移植 dive（参考原型：[wagoodman/dive](https://github.com/wagoodman/dive)，MIT）核心能力的工具集。

单仓库（monorepo）组织，四个包按依赖顺序推进：

- `oci-spec`：OCI image-spec 类型层（manifest / index / config / descriptor / platform），digest 解析与校验，media type 常量
- `layer-tree`：tar 层叠文件树 + `.wh.` whiteout 语义 + 层间 diff
- `dive-analysis`：镜像体积分析、跨层重复文件、efficiency score，输出报告
- `image-ci`：镜像体积门禁规则 DSL 与 CLI（exit code / CI 注解）

详见 `docs/` 下的设计文档。
