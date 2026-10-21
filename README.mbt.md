# dive

MoonBit 重写 [wagoodman/dive](https://github.com/wagoodman/dive)（Go，MIT）核心能力的工具集：
解析 OCI 镜像、层叠文件树、分析体积、做 CI 门禁。

参考原型而非移植对象——dive 依赖 docker/cli、gocui 等整套 Go 生态，MoonBit 侧无等价绑定。
本仓库吸收它的技术核心：四个包按依赖顺序推进，镜像获取（docker cli 封装）作为独立的第五个包：

- `oci_spec`：OCI image-spec 类型层（manifest / index / config / descriptor / platform）、digest 解析与校验、media type 常量
- `layer_tree`：tar 层叠文件树 + `.wh.` whiteout 语义 + 层间 diff（层支持 `tar` / `tar+gzip` / `tar+zstd`）
- `image_analysis`：镜像体积分析、跨层重复文件、efficiency score，输出报告
- `image_ci`：镜像体积门禁规则 DSL 与 CLI（exit code / CI 注解）——**已落地**，见 [`image_ci/README.mbt.md`](image_ci/README.mbt.md)
- `docker_cli`：Docker Engine 封装（docker/podman/nerdctl CLI 后端 + unix socket Engine 后端），把镜像名变成 tar/layout（独立包，不被前四包依赖）
- `registry_cli`：直接连 registry 拉镜像（OCI Distribution Pull），落成本地 tar / OCI layout，
  **不依赖本地 docker**（镜像引用在没有 docker 时自动走它，`--save` 也走它；native only）
- `tui`：全屏交互式看树（基于 `moonbit-community/tty`，native only，**CLI 的默认出口**），alternate screen + 带边框分栏，
  树与详情可 `Tab` 切焦点、`?` 出帮助，把逐层视图接成可上下走、可折叠、可切层的画面；
  键鼠都能用（点击选行 / 滚轮滚面板 / 右键切展开）

## 用一下

出口只有两个，**默认是界面**（issue #128）：能开界面就开界面，
`--no-tui` 才走文本。终端不够格（stdin/stdout 有一个不是 tty，或者镜像是从
stdin 喂进来的）时自动退到文本，并在 stderr 点一句 `tui skipped: ...`。

```bash
# 默认：开界面（上下走行、折叠目录、左右切层）。没有真终端时自动降级成报告
moon run --target native cmd/main -- demo-image.tar
moon run --target native cmd/main -- nginx:latest

# 随时要一份一次性报告：CI / 脚本 / 管道里都该加 --no-tui
moon run --target native cmd/main -- demo-image.tar --no-tui
moon run --target native cmd/main -- demo-image.tar --no-tui --rules rules.json

# 门禁：按 rules.json 判定，退出码 0/1/2 分别表示全过 / 有失败 / 规则非法
moon run --target native cmd/main -- demo-image.tar --no-tui --rules rules.json
moon run --target native cmd/main -- demo-image.tar --no-tui --rules rules.json --format annotations

# 逐层浏览：看第 N 层应用完之后的文件树与这层 diff
moon run --target native cmd/main -- demo-image.tar --no-tui --layer 1
moon run --target native cmd/main -- demo-image.tar --no-tui --layer 1 --path /app

# 界面里看完一圈，退出时把产物落盘：`-f` / `-o` 在界面那档同样有效
moon run --target native cmd/main -- demo-image.tar -f json -o report.json

# 按效率看路径：谁把 efficiency 分数拉下来的
moon run --target native cmd/main -- demo-image.tar --efficiency
moon run --target native cmd/main -- demo-image.tar --no-tui --efficiency
moon run --target native cmd/main -- demo-image.tar --no-tui --efficiency --top 20 --path /app
moon run --target native cmd/main -- demo-image.tar --no-tui --efficiency --format json

# 不落盘直接分析在线镜像：位置参数不是本地路径，就当镜像名
moon run --target native cmd/main -- nginx:latest
moon run --target native cmd/main -- nginx:latest --verbose
# 完全离线：一次网络请求都不发（不 pull、不连 registry）
moon run --target native cmd/main -- nginx:latest --no-pull
# 单次 docker 调用最多等多久（秒，默认 30），拉大镜像时调大
moon run --target native cmd/main -- nginx:latest --timeout 300

# 只把镜像存成 tar 或 OCI layout，不分析（`--save` 只对镜像引用生效）
moon run --target native cmd/main -- --save -o nginx.tar library/nginx:1.27
moon run --target native cmd/main -- --save --archive-format oci -o ./nginx-oci library/nginx:1.27
# 多架构选平台 / 自建 http registry / 私有仓库
moon run --target native cmd/main -- --save --platform linux/arm64 -o x.tar ghcr.io/owner/repo:tag
moon run --target native cmd/main -- --save --insecure-registry -o x.tar localhost:5000/team/app:dev
# 同时在途的层数（默认 4；1 = 逐层串行，排障用）
moon run --target native cmd/main -- --save --jobs 8 -o nginx.tar library/nginx:1.27
# 根证书不在系统默认位置：指定一份 PEM（`https://` registry 都要校验证书）
DIVE_CA_BUNDLE=/path/to/ca-bundle.crt moon run --target native cmd/main -- --save -o x.tar registry.example.com/team/app:1.0
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

**位置参数自己说它是什么**（[#124](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/124)）：
`-` 是 stdin，存在的路径是本地归档 / OCI layout（一步都不碰网络），其余当镜像引用。
不再有 `--from-image` / `--from-registry` 两个开关可挑。

镜像引用先问 docker：`inspect` 说本地有就 `save`，说没有就 `pull` 一次再 `save`；
直到**这台机器一个 docker 后端都没有**，才自己连 registry ——
自己当客户端，`token → manifest(index 按平台选) → blobs` 三段 HTTP 把镜像拉下来，
产物同样是 docker-archive tar，不碰 daemon。两者顺序不能对调：`docker save` 要求镜像
已经在 daemon 里。

`--save` 是「只取不分析」，`-o` 是落盘位置（docker-archive 写文件，
`--archive-format oci` 写目录）。它**只对镜像引用生效**：位置参数本来就指向一份本地
归档时会按参数错退 2——`--save` 不落盘还硬跑的唯一动机是想看网络通不通，
把一个已有的 tar 悄悄写进临时目录是最糟的一种「成功」。

拉取默认**边下边写盘**：层先落到临时文件（内存峰值是一块 64 KiB），
OCI layout 直接把它抄过去、docker-archive 再读回来解压；
`--jobs` 控制在途层数（默认 4），`--jobs 1` 退回逐层串行。
进度行在 stderr，带整体字节、滑动窗口速度，失败时交代断在第几层。
细节见 [`docs/p7-registry-cli.md`](docs/p7-registry-cli.md)。

镜像引用默认会「本地缺就先拉一次」再取，对齐原版 dive（Go）——那边没有 `--pull` 开关，
`ImageInspect` 报 not-found 就 `docker pull` 一次。`--no-pull` 一句话：
**本次运行绝不发起任何出网请求**。它拦的只有 `pull` 与 registry 直拉；
`inspect` / `save` 是纯本地操作，照常执行。所以它既不是「只看本地文件」，
也不是「禁止连 daemon」。

`--no-pull` 下的两种失败分开报：「本地没这个镜像」用户该 `docker pull`
（或去掉开关），「这台机器没有 docker」用户该装 docker —— 前者是
`image error: no such image locally ...`，后者是 `docker error: ...` 加安装提示。

这台机器上**一个 docker 后端都没有**（没装 docker / podman / nerdctl，也没有可用的
daemon socket）时，镜像引用会自己连 registry
（[#109](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/109)）：

```bash
# 没有 docker 也能跑：自动从 registry 拉
moon run --target native cmd/main -- docker.cnb.cool/owner/repo:tag
# --no-pull 关掉这个兜底：不上网就是不上网，直接报错并给安装提示
```

只有「一条能走的路都没有」才兜底。docker 在、只是这个镜像导不出来（daemon 挂着、
权限不够、镜像不在本地且拉取失败）时仍然报 docker 的错——拿一场注定失败的 registry
拉取盖住真原因是最坏的选择。

单次 docker 调用有 **30 秒默认空闲超时**（`--timeout` 调大）：这里的钟量的是
「多久没有任何输出」，不是总时长——`docker pull` 拉大镜像时进度一直在刷，
不会被误砍；真卡在 socket 上半死不动的，才会被收掉。后端探测与降级见
[`docker_cli/README.mbt.md`](docker_cli/README.mbt.md)。

`--timeout` 只包住 docker 调用。**取到归档之后的解压与叠树是纯本地计算，不受它约束**，
在很大的层上本身就要花时间——`--verbose` 会把这一段也点出来
（`fetched N bytes` → `parsing archive (decompress + stack layers)...`），
免得中间那段沉默被当成卡死。

`moon run` 默认跑 wasm，退出码只有 `--target native` 能传给 shell。输入认三种：
docker save 产物、OCI Image Layout 目录、单层 tar，或者一个镜像引用（`nginx:latest`）。

不给 `--no-tui` 就打开全屏交互式看树，**键位逐条对齐原版 dive**
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
它进 alternate screen（退出还原终端，异常退出也还原），只支持 native。
`stdin`/`stdout` 有一个不是 tty（`dive img > out.txt`、`| cat`），或者镜像是
从 stdin 喂进来的（`dive - < img.tar`，界面会把 tar 流吃掉）——这三种情况
都**在进 alternate screen 之前**判掉，落回文本出口，不留半截画面。
`--rules` 在界面那档同样是门禁：退出码仍是 `0/1/2`。
详见 [`tui/README.mbt.md`](tui/README.mbt.md) 与 [`docs/p6-tui.md`](docs/p6-tui.md)。

详见 [`docs/`](docs/README.md) 下的设计文档；进度看板见 issue #8；docker cli 封装见 issue #17；
交互式看树的落地进度见 issue #46（路径 A：#48；全屏路径 B：#49）。

