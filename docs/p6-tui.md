# P6 `tui`：交互式看树

[dive](https://github.com/wagoodman/dive)（Go，MIT）的交互式文件树在 MoonBit 上的实现。
本文记录分层、与既有链路的关系、以及本轮做/不做的边界。

## 缘由

[#27](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/27) 曾把「不做全屏 TUI」定为结论，
但留了活口：真要做全屏交互，另开实现 issue。[#46](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/46)
承接了这条活口，实测排掉三个前置阻塞项后，先按**路径 A（非全屏交互式看树）**落地
（#48：占主屏、底部一行状态条）；路径 A 跑通后按 [#49](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/49)
补上**路径 B（全屏 TUI）**：

- 进 alternate screen，带边框的分栏（树 / 详情），`Tab` 切焦点，`?` 出帮助浮层，
  退出时还原终端（含异常路径）
- 底层用 `moonbit-community/tty` 做终端原语（raw mode / alternate screen / 尺寸 /
  输入解码 / 光标与擦除）
- 数据全部来自既有链路（`layer_tree::browse_layers` + `image_analysis`），TUI 只是再包一层视图

## 阻塞项结论（#46 评论区实测）

| 阻塞项 | 结论 |
|---|---|
| a. async 版本对齐 | tty 0.5.0 声明 `async@0.22.4`，本仓 `0.22.5`；实测在本仓工具链下编译通过，`moon update` 能过 |
| b. 第三方文本库 | 本轮**不引** `grapheme` / `unicodewidth`，宽度自研（见下）。后由 #50 补上 grapheme cluster 口径：cluster 划分仍自研，只从 unicodewidth 的打包表生成一张零宽码点表（生成后不依赖对方） |
| c. target 收窄 | tty 只支持 native。按用户建议把 TUI 代码集中在独立包 `tui/`，并标 `supported_targets = "-all+native"`，与 `docker_cli` / `cmd/main` 同一套约定，避免模块级 `preferred_target = "wasm"` 和 native-only 依赖硬冲突 |

## 分层

```
tui/
├── screen.mbt       L0 字符画布（列×行），写入即标脏
├── width.mbt        L0 显示宽度与按列截断/补齐（按 grapheme cluster）
├── width_tables.mbt L0 零宽码点区间表（由 scripts/gen_width_tables.py 生成）
├── terminal.mbt     L0 画布 → 终端字节流（首帧全量、之后只吐脏格）
├── alt_screen.mbt   L0 alternate screen 的进/出序列（幂等，异常也还原）
├── layout.mbt       L1 分栏布局引擎：面板矩形 + 边框 + 内容区 + 帮助让位
├── viewport.mbt     L1 滚动视口（详情面板用）
├── components.mbt   L2 面板组件：画框 / 标题高亮 / 清内容区 / 溢出提示
├── tree_view.mbt    L2 树拍平成行 + 展开/折叠 + 滚动 + 光标
├── render.mbt       L2 画一帧
├── keys.mbt         L3 按键 → 动作 → 视图状态
├── mouse.mbt        L3 鼠标事件 → 动作（点击 / 滚轮 / 右键）
├── focus.mbt        L3 焦点顺序与循环
├── model.mbt        L4 分析结果 → 详情数据源
└── app.mbt          L4 主循环（进全屏 → 组帧 → 等事件 → 还原）
```

分层与 #46 的倒排（L0–L4）对应。路径 B 是在 L0–L4 各补一层，而不是换一套架构：

| 层 | 路径 A（#48） | 路径 B（#49） |
|---|---|---|
| L0 | 无 | `alt_screen.mbt`：进出序列、退出幂等 |
| L1 | 固定的「左树右详情」数字 | `layout.mbt` 面板矩形 + 边框 + 内容区；`viewport.mbt` |
| L2 | `render.mbt` 直接画 | `components.mbt` 抽成可复用组件 |
| L3 | 按键 → 视图 | `focus.mbt` 焦点显式化 + 切焦点 / 帮助键 |
| L4 | 主屏主循环 | 同一主循环 + 全屏进出与还原 |

每层可独立验收：L0/L1 是纯计算与纯布局，L2 是纯状态机，L3 是按键与焦点映射，
L4 才有副作用（终端 IO）。

## 关键取舍

### 按列排版，宽度自研

CJK 占两列、组合字符零宽。只按 `String::length` 排版，中文目录名会把整栏对齐带歪。

量的是 **grapheme cluster**，不是码点：ZWJ 家族 emoji（`👨‍👩‍👧‍👦`）在终端里只画一个字形、
占 2 列，按码点相加会算成 8 列，文件名右侧的大小 / 层号对齐会整体歪掉。
`width.mbt` 先划 cluster，簇宽由簇内第一个有宽度的码点定；VS16 会把 keycap 从 1 列抬到 2 列。

不引 `kawaz/grapheme` + `moonbit-community/unicodewidth`：cluster 划分自研，
只从 unicodewidth 的打包表生成一张零宽码点表（`scripts/gen_width_tables.py` →
`width_tables.mbt`，Unicode 16.0 的 Mn/Me/Cf），表落地后本仓不依赖它。
引库会把「文本测量」这个本可独立验收的点绑死在别人的版本上（`unicodewidth` 还钉着
`x@0.4.44`，与本仓 `x@0.5.5` 有收敛风险）。

### 不做样式

前景/背景/加粗本轮用不到，带上它会让「缓冲 diff」和「SGR 序列拼接」两件事缠在一起。
`Screen` 只存字符，焦点靠边框标题的 `>` 标记表达（不用反白），配色留到需要时再加一层。

### 退出还原

全屏占的是 alternate screen，正常退出回到主屏、滚上去的 shell 输出原封不动；
中途 panic / Ctrl+C / 任务取消才是问题现场。两条保护叠起来：

1. `with_raw_mode`（全屏同样要 raw mode）
2. `AltScreen::leave` 的 `defer @async.protect_from_cancel`，且幂等

`teardown_commands()` 把「退出发什么」抽成纯函数并钉死顺序：
复位样式 → 显示光标 → 离开 alternate screen。顺序不能换——
切换缓冲区会清屏并作用到主屏上。

### 焦点

路径 A 只有一个能动的东西（树的光标），全屏下有两块会滚的面板，
键盘得先知道「这一下给谁」。焦点是 `Focus::{Tree, Detail}`，
顺序与循环在 `focus.mbt` 里纯函数化。状态行与帮助浮层不接焦点：
把 `Tab` 停在没有交互的面板上只会让人以为按键失灵。
窄屏下详情栏没有位置，但焦点留在它身上不算错——拉宽后面板会回来。

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
全屏的进出由 `@tui.run_app` 自己管，`cmd/main` 只提供 raw mode 那一层保护。

## 非目标

- 样式与配色（前景/背景/加粗）
- 鼠标拖拽 / 框选（点击与滚轮已接，见下）
- 边看边改（TUI 是只读视图，不产生镜像变更）

## 鼠标与坐标反查（#51）

#48/#49 版本只有「行下标 → 屏幕行」这一个方向，鼠标落地需要反向那一句。本轮补上：

- `TreeView::index_at_screen_row`：内容区相对行 → 可见行下标，与渲染的
  `offset + row` 严格互逆（测试按互逆关系钉）；`select_at_screen_row` 顺手落光标
- `mouse.mbt`：`MouseEvent` → `MouseAction`（`Select` / `ScrollUp` / `ScrollDown` /
  `ToggleFold` / `SetFocus`），纯查表，可单测
- `app.mbt` 的 `hit_test`：屏幕绝对坐标 → `(面板, 面板内相对行)`，按外框判定
  （点边框也算点到面板）；`handle_mouse` 再把它施加到状态上
- 布局记在 `AppState.last_layout`（画帧时回填），不在事件处理里重算——
  重算要终端尺寸，而事件处理是同步的

鼠标跟踪用 `Click` 模式，与进出全屏配对：`run_app` 里 `enable_mouse` /
`disable_mouse` 一对 `defer`。漏关掉会让**退出后的 shell** 把每次点击吐成
一段 `\x1b[<...` 垃圾，所以关它排在切回主屏之前。

顺带补了一个纯键盘可达的排序键 `s`（按名字 ↔ 按体积）：右键切展开态本身
与键盘的 `Enter` 同效，排序却没有对应键，只做鼠标会让键鼠两套操作不对称。

## 全屏形态的验收（#49）

- 树 / 详情两块面板可 `Tab` 切换焦点，聚焦的那块边框标题带 `>`
- 帮助浮层 `?` 开关，铺在主体下半部分，挤不下时自动不显示
- 窄屏退化单栏，详情栏没有位置但不影响焦点状态
- 异常退出（panic / Ctrl+C）后终端还原：`teardown_commands()` 有单测钉住三件事与顺序
- `moon test --target native` 全绿；关键交互（布局、视口、焦点、按键、组件、退出序列）
  都有测试覆盖，真终端行为靠 CLI 冒烟

## 鼠标的验收（#51）

- 滚轮能滚动树（光标走 3 行）与详情（视口走 3 行），滚的是鼠标停着的那块，不用先点
- 点击树行的行号与画面上那行一致；滚动之后反查跟着 `offset` 走，不偏行
- 点面板里的空白格什么都不做（不选行、不抢焦点）
- 窄屏退化单栏时，右栏坐标落不到详情面板上（面板不存在就不该被命中）
- `moon test --target native -p tui` 全绿，`mouse_test.mbt` / `mouse_wbtest.mbt`
  覆盖映射与命中，真终端行为靠 CLI 冒烟
