# dive

MoonBit 重写 [wagoodman/dive](https://github.com/wagoodman/dive)（Go，MIT）核心能力的工具集：
解析 OCI 镜像、层叠文件树、分析体积、做 CI 门禁。

参考原型而非移植对象——dive 依赖 docker/cli、gocui 等整套 Go 生态，MoonBit 侧无等价绑定。
本仓库吸收它的技术核心：四个包按依赖顺序推进，镜像获取（docker cli 封装）作为独立的第五个包：

- `oci_spec`：OCI image-spec 类型层（manifest / index / config / descriptor / platform）、digest 解析与校验、media type 常量
- `layer_tree`：tar 层叠文件树 + `.wh.` whiteout 语义 + 层间 diff
- `image_analysis`：镜像体积分析、跨层重复文件、efficiency score，输出报告
- `image_ci`：镜像体积门禁规则 DSL 与 CLI（exit code / CI 注解）——**已落地**，见 [`image_ci/README.mbt.md`](image_ci/README.mbt.md)
- `docker_cli`：Docker Engine 封装（docker/podman/nerdctl CLI 后端 + unix socket Engine 后端），把镜像名变成 tar/layout（独立包，不被前四包依赖）

## 用一下

```bash
# 只体检：打印体积报告与一句 gate 结论
moon run --target native cmd/main -- demo-image.tar

# 门禁：按 rules.json 判定，退出码 0/1/2 分别表示全过 / 有失败 / 规则非法
moon run --target native cmd/main -- demo-image.tar --rules rules.json
moon run --target native cmd/main -- demo-image.tar --rules rules.json --format annotations

# 逐层浏览（dive 交互界面的只读替身）：看第 N 层应用完之后的文件树与这层 diff
moon run --target native cmd/main -- demo-image.tar --layer 1
moon run --target native cmd/main -- demo-image.tar --layer 1 --path /app

# 按效率看路径：谁把 efficiency 分数拉下来的
moon run --target native cmd/main -- demo-image.tar --efficiency
moon run --target native cmd/main -- demo-image.tar --efficiency --top 20 --path /app
moon run --target native cmd/main -- demo-image.tar --efficiency --format json

# 不落盘直接分析在线镜像：位置参数当镜像名，走 docker_cli 取归档
moon run --target native cmd/main -- nginx:latest --from-image
moon run --target native cmd/main -- nginx:latest --from-image --verbose
# 完全离线：本地缺镜像也不拉，一次网络请求都不发
moon run --target native cmd/main -- nginx:latest --from-image --no-pull
# 单次 docker 调用最多等多久（秒，默认 30），拉大镜像时调大
moon run --target native cmd/main -- nginx:latest --from-image --timeout 300
```

给了 `--layer` / `--path` 就不做门禁判定，只出那一层的树；`--layer` 从 0 起，
`--path` 按目录下钻（沿途祖先目录保留作缩进参照）。没有 TUI，交互靠 shell 补。

`--efficiency` 同样不做门禁，只出「按多写了几份排的路径表」
（每行 `path` / `versions` / `cumulative` / `min` / `size`），
`--top` 限条数（`0` 表示全都要），`--path` 当前缀过滤，`--format json` 可脚本化。
这个表的 `size` 是 `cumulative - min`，**与报告里 `wasteful paths` 的 `wasted_bytes`
不是同一个数**，口径差异见 [`image_analysis/README.mbt.md`](image_analysis/README.mbt.md)。

`--from-image` 把位置参数当镜像名：本地缺这个镜像时**默认先拉一次**再取，
对齐原版 dive（Go）——那边没有 `--pull` 开关，`ImageInspect` 报 not-found 就
`docker pull` 一次。要完全离线（绝不发起网络请求、`inspect` 说没有就直接 `save`）
加 `--no-pull`。

单次 docker 调用有 **30 秒默认超时**（`--timeout` 调大）：socket 半死时不给超时
就会静默挂住，啥也看不到。后端探测与降级见
[`docker_cli/README.mbt.md`](docker_cli/README.mbt.md)。

`moon run` 默认跑 wasm，退出码只有 `--target native` 能传给 shell。输入认三种：
docker save 产物、OCI Image Layout 目录、单层 tar（或加 `--from-image` 给镜像名）。

详见 [`docs/`](docs/README.md) 下的设计文档；进度看板见 issue #8；docker cli 封装见 issue #17。

