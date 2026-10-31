# 仓库结构与开发约定

单仓库（monorepo）承载七个包：P1–P4 是分析链路，P5 `docker_cli` / P6 `tui` /
P7 `registry_cli` 各自独立，避免多仓库同步成本。

## 结构

```
moon.mod                # PaiGack/dive
moon.pkg                # 根包占位
cmd/main/               # 总 CLI 入口（聚合 P1–P4，接线 P5/P7 的取镜像）
oci_spec/               # P1
layer_tree/             # P2
image_analysis/         # P3
image_ci/               # P4（含本地输入识别 ImageSource::load）
docker_cli/             # P5（独立包，不被 P1–P4 依赖）
tui/                    # P6（native only，交互式看树）
registry_cli/           # P7（独立包，直连 registry 取镜像）
docs/                   # 设计文档与拆分规划
scripts/                # CI 脚本（ci.sh / docker-cli-probe.sh）
```

`cmd/main/` 只做接线，判定逻辑都在 `image_ci` 里。它撑起三个出口：

- **默认是界面**（P6）。能开就开：`isatty(stdin) && isatty(stdout)` 为真时进全屏
  看树，`--no-tui` 才走文本。`dive img > out.txt`、`dive - < img.tar` 这类
  「终端状态不够格」的情况在切屏**之前**就退到文本。
- **文本出口**（`--no-tui`）：`dive <image> [--rules rules.json]
  [--format text|json|html|annotations] [-o out]`，输出体积报告 + 门禁判定，
  退出码按 `image_ci` 的 0/1/2。
- **只读视图**：`dive <image> --layer N [--path P] [--aggregate]` 打印某一层的
  文件树与该层 diff；`--efficiency` 打印逐路径效率表。给了这三个开关就不做门禁判定。
  `--path` 按目录下钻，文本与 JSON 两个输出口都只给子树（沿途祖先目录留作缩进参照）。
  实现落在 `layer_tree::browse_layers`。

P6 `tui` 是交互式看树，底层用 `moonbit-community/tty`，因此与 `docker_cli` 一样标
`supported_targets = "-all+native"`，只支持 native。数据来自 P2 的 `browse_layers` 与
P3 的分析结果，TUI 只再包一层视图。设计见 [p6-tui.md](p6-tui.md)。

P5 `docker_cli` 已按同样约定落地（`moon.pkg` + README + 测试），见 [issue #17](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/17)。
它只支持 native（`supported_targets = "-all+native"`）：进程与 unix socket
在别的后端上没有入口。

P7 `registry_cli` 同样只支持 native（`supported_targets = "-all+native"`），见 [p7-registry-cli.md](p7-registry-cli.md)。
它是「这台机器一个 docker 后端都没有」时的兜底数据源，产物仍是 docker-archive tar
或 OCI layout，交回 `image_ci::ImageSource::load` 那个唯一入口。

## 开发工作流

- `moon check` 提交前必跑（`.githooks/pre-commit` 已配置）
- `docker_cli` / `registry_cli` / `tui` / `image_ci` / `cmd/main` 都标了
  `supported_targets = "-all+native"`，`moon test` 要给 target，例如
  `moon test -p docker_cli --target native`；`layer_tree` 多一个 `wasm-gc`、
  `image_analysis` 是 `wasm-gc+native`
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
