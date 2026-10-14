# dive

MoonBit 重写 [wagoodman/dive](https://github.com/wagoodman/dive)（Go，MIT）核心能力的工具集：
解析 OCI 镜像、层叠文件树、分析体积、做 CI 门禁。

参考原型而非移植对象——dive 依赖 docker/cli、gocui 等整套 Go 生态，MoonBit 侧无等价绑定。
本仓库吸收它的技术核心：四个包按依赖顺序推进，镜像获取（docker cli 封装）作为独立的第五个包：

- `oci_spec`：OCI image-spec 类型层（manifest / index / config / descriptor / platform）、digest 解析与校验、media type 常量
- `layer_tree`：tar 层叠文件树 + `.wh.` whiteout 语义 + 层间 diff
- `dive_analysis`：镜像体积分析、跨层重复文件、efficiency score，输出报告
- `image_ci`：镜像体积门禁规则 DSL 与 CLI（exit code / CI 注解）——**已落地**，见 [`image_ci/README.mbt.md`](image_ci/README.mbt.md)
- `docker_cli`：Docker Engine 封装（docker/podman/nerdctl CLI 后端 + unix socket Engine 后端），把镜像名变成 tar/layout（独立包，不被前四包依赖）

## 用一下

```bash
# 只体检：打印体积报告与一句 gate 结论
moon run --target native cmd/main -- demo-image.tar

# 门禁：按 rules.json 判定，退出码 0/1/2 分别表示全过 / 有失败 / 规则非法
moon run --target native cmd/main -- demo-image.tar --rules rules.json
moon run --target native cmd/main -- demo-image.tar --rules rules.json --format annotations
```

`moon run` 默认跑 wasm，退出码只有 `--target native` 能传给 shell。输入认三种：
docker save 产物、OCI Image Layout 目录、单层 tar。

详见 [`docs/`](docs/README.md) 下的设计文档；进度看板见 issue #8；docker cli 封装见 issue #17。

