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
- `tui`：全屏交互式看树（基于 `moonbit-community/tty`，native only），alternate screen + 带边框分栏，
  树与详情可 `Tab` 切焦点、`?` 出帮助，把逐层视图接成可上下走、可折叠、可切层的画面；
  键鼠都能用（点击选行 / 滚轮滚面板 / 右键切展开）

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

# 全屏交互式看树（TUI）：上下走行、折叠目录、左右切层
moon run --target native cmd/main -- demo-image.tar --tui
moon run --target native cmd/main -- nginx:latest --from-image --tui

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

报告与 TUI 面板上叫 `wasted` 的那个数取的是前者（`cumulative - min`，dive 的
`inefficientBytes`），所以它与 `wasted.overwritten + deleted` 对不上；JSON 里
两个都给（`image.wastedBytes` 与 `image.wasted.{overwritten,deleted}`），
外加 dive 的 `image.userWastedPercent`（分母剔掉 base image）。

`--from-image` 把位置参数当镜像名：本地缺这个镜像时**默认先拉一次**再取，
对齐原版 dive（Go）——那边没有 `--pull` 开关，`ImageInspect` 报 not-found 就
`docker pull` 一次。要完全离线（绝不发起网络请求、`inspect` 说没有就直接 `save`）
加 `--no-pull`。

单次 docker 调用有 **30 秒默认超时**（`--timeout` 调大）：socket 半死时不给超时
就会静默挂住，啥也看不到。后端探测与降级见
[`docker_cli/README.mbt.md`](docker_cli/README.mbt.md)。

`--timeout` 只包住 docker 调用。**取到归档之后的解压与叠树是纯本地计算，不受它约束**，
在很大的层上本身就要花时间——`--verbose` 会把这一段也点出来
（`fetched N bytes` → `parsing archive (decompress + stack layers)...`），
免得中间那段沉默被当成卡死。

`moon run` 默认跑 wasm，退出码只有 `--target native` 能传给 shell。输入认三种：
docker save 产物、OCI Image Layout 目录、单层 tar（或加 `--from-image` 给镜像名）。

`--tui` 打开全屏交互式看树，**键位逐条对齐原版 dive**
（`cmd/dive/cli/internal/ui/v1/key/config.go` 的 `DefaultBindings()`）：
`↑↓`/`jk` 走行，`←→`/`hl` 收起展开，`Space` 折叠展开（`Ctrl+Space` 全折全展），
`PgUp`/`PgDn` 翻页（`u` 是 `pgup` 别名，`d` 给了删除列表），
`Tab` 换视图（树 ↔ 详情），`Ctrl+A`/`Ctrl+L` 切「聚合 / 当前层」diff 档位，
`Ctrl+U` 只看被改写的行，`Ctrl+C` 退出；本仓另有 `[`/`]` 换层、`s` 切排序
（名字 ↔ 体积）、`?` 开关帮助浮层、`q`/`Esc` 退出。
文件属性（权限 / mtime / 层号）常显在详情面板里。
鼠标同样可用：点击选行（点目录顺带开合）、滚轮滚鼠标停着的那块面板、
右键切目录展开态；`Ctrl` + 左右键切焦点。
详情面板跟着光标走：选中路径的账（permissions / mtime / layer +
efficiency / wasted / total + versions / cumulative / min / overhead），
下面是整镜像的 inefficient files 表（`count / total space / path`，
与 `--efficiency` 同一批数字）。
原版里**不做**的是 `Ctrl+F` 过滤与 `Ctrl+E` 抽文件，理由见
[`docs/p6-tui.md`](docs/p6-tui.md) 的「与 dive 键位表的差异说明」。
它进 alternate screen（退出还原终端，异常退出也还原），只支持 native，
且需要一个真终端（stdin/stdout 都不是 tty 时退 exit 2）。
详见 [`tui/README.mbt.md`](tui/README.mbt.md) 与 [`docs/p6-tui.md`](docs/p6-tui.md)。

详见 [`docs/`](docs/README.md) 下的设计文档；进度看板见 issue #8；docker cli 封装见 issue #17；
交互式看树的落地进度见 issue #46（路径 A：#48；全屏路径 B：#49）。

