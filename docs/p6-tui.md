# P6 `tui`：交互式看树

[dive](https://github.com/wagoodman/dive)（Go，MIT）的交互式文件树在 MoonBit 上的实现。
本文记录分层、与既有链路的关系、以及本轮做/不做的边界。

## 缘由

[#27](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/27) 曾把「不做全屏 TUI」定为结论，
但留了活口：真要做全屏交互，另开实现 issue。[#46](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/46)
承接了这条活口，实测排掉三个前置阻塞项后，按**路径 A（非全屏交互式看树）**落地：

- 占主屏、底部一行状态条，不切 alternate screen、不做分栏布局引擎
- 底层用 `moonbit-community/tty` 做终端原语（raw mode / 尺寸 / 输入解码 / 光标与擦除）
- 数据全部来自既有链路（`layer_tree::browse_layers` + `image_analysis`），TUI 只是再包一层视图

## 阻塞项结论（#46 评论区实测）

| 阻塞项 | 结论 |
|---|---|
| a. async 版本对齐 | tty 0.5.0 声明 `async@0.22.4`，本仓 `0.22.5`；实测在本仓工具链下编译通过，`moon update` 能过 |
| b. 第三方文本库 | 本轮**不引** `grapheme` / `unicodewidth`，宽度自研（见下）；真要做 grapheme cluster 再议 |
| c. target 收窄 | tty 只支持 native。按用户建议把 TUI 代码集中在独立包 `tui/`，并标 `supported_targets = "-all+native"`，与 `docker_cli` / `cmd/main` 同一套约定，避免模块级 `preferred_target = "wasm"` 和 native-only 依赖硬冲突 |

## 分层

```
tui/
├── screen.mbt       L0 字符画布（列×行），写入即标脏
├── width.mbt        L0 显示宽度与按列截断/补齐
├── terminal.mbt     L0 画布 → 终端字节流（首帧全量、之后只吐脏格）
├── layout.mbt       L1 分栏（标题 / 左右主体 / 状态行），窄屏退化单栏
├── tree_view.mbt    L2 树拍平成行 + 展开/折叠 + 滚动 + 光标
├── render.mbt       L2 画一帧
├── keys.mbt         L3 按键 → 动作 → 视图状态
├── model.mbt        L4 分析结果 → 详情数据源
└── app.mbt          L4 主循环
```

分层与 #46 的倒排（L0–L4）对应。每层可独立验收：L0/L1 是纯计算与纯布局，
L2 是纯状态机，L3 是按键映射，L4 才有副作用（终端 IO）。

## 关键取舍

### 按列排版，宽度自研

CJK 占两列、组合字符零宽。只按 `String::length` 排版，中文目录名会把整栏对齐带歪。
`width.mbt` 用 wcwidth 的常用近似（组合字符零宽、东亚宽 / emoji 主区占两列）。

不引 `kawaz/grapheme` + `moonbit-community/unicodewidth`：本轮画面只要 ASCII + 常见 CJK 就够，
引第三方会把「文本测量」这个本可独立验收的点绑死在别人的版本上（`unicodewidth` 还钉着
`x@0.4.x`，与本仓 `x@0.5.5` 有收敛风险）。接口只有 `display_width` / `char_width`，
真要做 ZWJ emoji 序列再换实现即可，不牵动画面代码。

### 不做样式

前景/背景/加粗本轮用不到，带上它会让「缓冲 diff」和「SGR 序列拼接」两件事缠在一起。
`Screen` 只存字符，配色留到需要时再加一层。

### 增量重画

每帧和上一帧逐格比对，只吐变化的格子。`Screen::set` 时置脏位，重画时
「脏了**且**与基线不同」才算差异（写回原值不重画）。首帧 / resize 才做全量。
每帧在 `tty.with_synchronized_update` 里下发，终端当一次原子刷新，避免撕裂。

### 换层用回调注入

`keys.mbt` 的 `apply_action` 收一个 `switch_layer` 回调：视图只管「光标在哪」，
取另一层的树是数据源的事，键盘逻辑因此完全不依赖 `layer_tree`，可纯单测。

### 与 CLI 的关系

`--tui` 是 `cmd/main` 的一个开关，不是新的子命令。退出码只有 `0` / `2`：
它不是门禁判定，是一张可上下走的视图。给了 `--layer` 就作为 TUI 的起始层，
不给则默认看最后一层（与原 `--layer` 缺省一致）。

## 非目标

- 全屏 TUI（alternate screen / 分栏布局引擎 / 组件库）——路径 B，另议
- 样式与配色
- 鼠标事件（tty 已解出，但本轮不接）
- grapheme cluster 级别的文本测量
- 边看边改（TUI 是只读视图，不产生镜像变更）
