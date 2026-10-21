# 鼠标点击展开/折叠目录：调研与方案

[#62](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/62)：现在展开/折叠只能靠方向键，
鼠标点目录行不会开合。本文是调研结论与候选方案，**不含实现**。

## 一、现状（读码 + 实测）

### 1. 代码上其实「已经能折」，只是键位没人猜得到

`tui/app.mbt` 的 `handle_mouse` 里 `MouseAction::ToggleFold` 分支存在，绑定在**右键**上：

```moonbit
@input.MouseEventKind::Press(@input.MouseButton::Right) =>
  MouseAction::ToggleFold
```

左键是 `Select`——只落光标、切焦点。所以现象不是「没实现」，而是：

- 左键点目录行 = 只选中，不开合
- 右键点目录行 = 开合（符合 `dive` 原版，但没有任何地方提示，帮助浮层里也只有一行
  `right click fold / unfold the row under the pointer`）

### 2. 左键不加「点开合」是**上一轮的有意取舍**，不是遗漏

`docs/p6-tui.md` 的「鼠标与坐标反查（#51）」写着：右键切展开态与键盘 `Enter` 同效，
并解释右键是照 `dive` 的直觉。也就是说左键只选行，是为了让「点哪选哪」这件事单纯。

### 3. 那条「左键点不了」的路径在真终端上还额外断了一截

这是本轮**实测发现的新问题**，它把「点不动」放大了：

`tui/style.mbt`（tty 0.5.0）的 `Tty::enable_mouse` 只开两个模式位：

```
1000h（按下/松开上报） + 1006h（SGR 扩展坐标）
```

而 `tui/` 的样式层已经用 **kitty 键盘协议的像素坐标扩展**上报鼠标
（触发条件是 `CSI <` 继续以数字为**中间字节**，见 tty 源码
`internal/input/decoder.mbt::read_csi`：`0x20..<0x30 => seen_intermediate = true`，
后续 `0x30..<0x40` 直接判 `Unknown`）。

一旦终端按 kitty 扩展发 `CSI <cb;x;y;...M`，tty 的鼠标解析器会：

- 多出来的子参数 → `parse_subparams` 返回 `None` → `Unknown`
- `?1000h` 下只报按下，`?1000` 的 cb 没有「按住移动」这一档

结果是**点目录行连选中都不做**（不是只不折叠）。默认的 xterm / iTerm2 / kitty（未开
`mouse-reporting` 扩展）不受影响；开了扩展的终端上，整个树是「点不动」的。

> 待验证：本条结论来自读 tty 0.5.0 源码推导，没在本地起真终端（见第五节验证条件）。
> 判定方式很便宜：`moon run --target native cmd/main -- demo.tar`（`#128` 之前是 `--tui`），
> 点一下树行，若连选中都不亮，即为此条。

## 二、候选方案

### 方案 A：左键点目录行即切展开（推荐）

`MouseAction::Select` 落在目录行上时顺带 `toggle()`，文件行仍只选中。

- 符合「鼠标点目录 → 开合」的普遍直觉（VS Code / 文件管理器 / GitHub 都是这个手感）
- 键鼠对称：键盘 `Enter` 就是「切展开态」，左键对齐它；右键保持原样，老手感不丢
- 改动面小：只在 `handle_mouse` 的 `Select` 分支加一句，`TreeView` 层不动
- 代价：想让目录「只选中不开合」没有了（挪到 Ctrl+左键？但那是切焦点）——
  实践中这个需求很弱，`j/k` 也能只走光标

取舍细节：命中点在**折叠标记**（`+`/`-`，行首 3-4 列）上时切展开、点在名字上时只选中？
`dive` 与多数 TUI 不做这种区分，一处判定反而更好猜。建议**整行一致**。

### 方案 B：左键双击切展开

单击选中、双击开合，和 GUI 文件管理器一致。

- 需要给鼠标事件加「上一次点击的时间 + 坐标」状态，`action_of_mouse` 从纯函数
  变成带状态，`mouse_test.mbt` 的查表式测试也得跟着改
- TUI 里双击手感一般（没有 hover 反馈，第二下点在哪全凭手稳）
- 优点是不破坏「左键只选行」

### 方案 C：维持只右键，只补提示

帮助浮层 / 状态行里把右键写得更显眼，不改行为。

- 零风险，但用户报的就是「点不开」，只补文档大概率不解决

### 方案 D（建议和 A 一起做）：鼠标跟踪改 `Drag` 模式，并抵御 kitty 扩展

- `@tty.MouseTrackingMode::Drag`（`1002h`）而不是 `Click`（`1000h`）：
  按住拖动也会上报，cb 里的「按住移动」档能正常解出来；顺带保住「拖到边框调大小」这类
  以后可能加的手势。`#51` 当时选 `Click` 是因为「拖拽不是本轮目标」，代价是少一档事件
- kitty 扩展的防御：`CSI <` 后面出现**非数字中间字节**时，把鼠标报告**降级丢弃**
  而不要整段 `Unknown`——`Unknown` 会在主循环里静默消失，用户只会觉得「点了没反应」。
  降级要么按扩展格式解析（tty 0.5.0 不支持），要么至少在 `handle_mouse` 里
  打个可诊断的日志（TUI 里没地方打，退而求其次：`?` 帮助里说明「某些终端需关掉
  kitty mouse reporting」）

## 三、建议

先做 **A**（+ **D** 的 `Drag`），C 作为顺带：帮助浮层里补一句左键也能开合。
B 不做——为它引状态不划算。

### 已按 A + D + C 落地

调研拍板后按这个组合实现（B 不做），改动点：

- `TreeView::toggle_fold_at_screen_row`：坐标反查 + 落光标 + 切展开态，
  左键与右键共用；`toggle` 对非目录行是空操作，所以「点目录开合、
  点文件只选中」不额外分叉
- `handle_mouse` 的 `Select` 分支改调它（右键那条也折成同一个函数）
- `mouse_tracking_mode()`：默认 `Drag`（`?1002h`），像素鼠标终端上退到
  `Motion`（`?1003h`）
- `resolve_mouse(event, viewport_cols, viewport_rows)`：像素坐标折回格子坐标。
  第一节第 3 条那截「`Unknown` 静默消失」由此兜住——**本轮已在 tty 0.5.0
  源码 checkout 上实测**（`parse_sgr_mouse` 对 `CSI <0;10;5;1M` 返回 `Unknown`，
  对 `CSI <0;10;5M` 正常返回 `Mouse(Press(Left), row 5, col 10)`），
  不再是纯读码推导。折回格子后点击落在正确位置；贴边界时夹回视口内
- 帮助浮层那一行改成 `click  select; on a folder also fold / unfold`（C）

`moon test --target native -p tui` 164 条全绿（原 156 + 新增 8）。
真正起终端点一遍仍然没做（本环境没有可交互 pty），这一条保留在第五节。

## 四、验收口径（无论选哪个方案）

- 左键点目录行 → 开合；点文件行 → 只选中（`mouse_wbtest.mbt` 补两条）
- 右键行为不变（已有测试继续绿）
- 点面板空白格 / 点边框 → 什么都不做（已有测试继续绿）
- 折叠后再点同一行 → 展开，光标停在该目录行上（不跑到底）
- `moon test --target native -p tui` 全绿；真终端上界面（`#128` 之后是默认出口，不再需要 `--tui`）冒烟一遍

## 五、没做到的（更新于落地之后）

- **没起真终端点一遍**：本环境没有可交互的 pty。第一节第 3 条那截已用
  tty 0.5.0 源码 checkout 上的 `parse_csi` 实测钉住（`CSI <0;10;5;1M` → `Unknown`），
  但「真终端上报什么形状」仍靠 kitty 协议文档与这次换算兜底
- 没有统计「哪些终端默认开 kitty mouse reporting」——这决定第 3 条的实际影响面
