# tui

[dive](https://github.com/wagoodman/dive)（Go，MIT）的**交互式看树**在 MoonBit 上的实现：
在终端里上下走文件树、折叠目录、左右切层，右侧跟一张选中路径的体积详情。

底层用 [`moonbit-community/tty`](https://moonbitlang.github.io/mooncakes/moonbit-community/tty/)
做终端原语（raw mode / alternate screen / 尺寸 / 输入解码 / 光标与擦除）。

形态是 [#27](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/27) 里说的
**路径 B：全屏 TUI**——进 alternate screen、带边框的分栏、树与详情两块面板可切焦点、
`?` 出帮助浮层，退出时把终端还原成进来前的样子。
路径 A（占主屏、底部一行状态条）已经由 [#48](https://cnb.cool/nrzhangsan/moonbit_dive/-/pulls/48)
落地，全屏形态在它之上补了三层，分层见下。

键盘之外还能用鼠标（[#51](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/51)）：
点击选行、滚轮滚鼠标停着的那块面板、右键切目录展开态、`s` 切排序口径。

## 分层

```
screen.mbt      L0 按列×行的字符画布；写入即标脏，供增量重画
width.mbt       L0 显示宽度（按 grapheme cluster：CJK 两列、ZWJ emoji 一簇两列）与按列截断/补齐
width_tables.mbt L0 零宽码点区间表（生成，勿手改；见 scripts/gen_width_tables.py）
terminal.mbt    L0 画布 → 终端字节流：首帧全量、之后只吐脏格
alt_screen.mbt  L0 alternate screen 的进/出序列，退出幂等、异常也还原
layout.mbt      L1 分栏布局引擎：面板矩形 + 边框 + 内容区 + 帮助浮层让位
viewport.mbt    L1 滚动视口：偏移 + 夹取，详情面板复用
components.mbt  L2 面板组件：画框、标题高亮、清内容区、溢出提示
tree_view.mbt   L2 树拍平成可上下走的行 + 展开/折叠 + 滚动 + 光标
render.mbt      L2 画一帧：标题、两块面板、状态行、帮助浮层
keys.mbt        L3 按键 → 动作；动作 → 视图状态（换层用回调注入）
mouse.mbt       L3 鼠标事件 → 动作（点击 / 滚轮 / 右键），坐标留给 L4 命中
focus.mbt       L3 焦点管理：顺序、循环、窄屏下的可见性
model.mbt       L4 把 image_analysis 的结果压成详情数据源（吃已解压的层）
app.mbt         L4 主循环：进全屏 → 取尺寸 → 组帧 → 等事件 → 退出还原
                （`handle_mouse` / `hit_test` 把屏幕坐标换算成面板 + 行号）
```

数据全部来自既有链路（`layer_tree` + `image_analysis`），TUI 只负责再包一层视图，
不新开分析逻辑。层**只解压一遍**：`decompress_layers` 的产物同时喂给
`browse_decompressed`（逐层快照）与 `analysis_of_decompressed`（跨层统计），
两条链路共用同一批 tar 字节（issue #52）。

## 快速开始

```moonbit check
///|
test "README example" {
  // 造一个两层的树：L1 把 /app/main 改写了
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main", "x"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "yyyy"),
  ])
  let layers : Array[BytesView] = [l0, l1]
  // 解压一遍，视图与详情都从它出
  let decompressed = @layer_tree.decompress_layers(layers) catch {
    err => fail(err.to_string())
  }
  let views = @layer_tree.browse_decompressed(decompressed)

  // 建状态：默认看第 0 层，焦点在树上
  let state = @tui.AppState::new(views, None, "demo:latest")
  assert_eq(state.view.layer, 0)
  assert_eq(state.view.visible.length(), 2)
  assert_eq(state.focus, @tui.Focus::Tree)

  // 走行 + 折叠 + 换层
  state.view.move_down()
  assert_eq(state.view.cursor, 1)
  state.view.move_to(state.view.index_of_path("/app").unwrap())
  state.view.toggle()
  assert_true(state.view.collapsed.contains("/app"))
  state.switch_layer(1)
  assert_eq(state.view.layer, 1)

  // 全屏的布局：两块面板各带边框，内容区比外框内缩一格
  let layout = @tui.Layout::compute(80, 24)
  assert_eq(layout.left_width(), 38)
  assert_eq(layout.right_width(), 37)
  assert_eq(layout.tree_inner_origin(), (1, 2))

  // 焦点切换：Tab 在树与详情之间循环
  assert_eq(state.focus.next(), @tui.Focus::Detail)
  assert_eq(state.focus.next().next(), @tui.Focus::Tree)
}
```

## 命令行

`--tui` 是 `cmd/main` 的一个开关，与只读报告共用同一条取镜像链路：

```bash
# 本地 tar
moon run --target native cmd/main -- demo-image.tar --tui

# 在线镜像：先取归档，再进交互
moon run --target native cmd/main -- nginx:latest --from-image --tui

# 从指定层开始看（`--layer` 同时是 TUI 的起始层）
moon run --target native cmd/main -- demo-image.tar --tui --layer 0
```

按键（`?` 里也有一份）：

| 键 | 动作 |
|---|---|
| `↑` `↓` / `k` `j` | 走行（焦点在详情时：滚动） |
| `PgUp` `PgDn` / `b` `Space` | 翻页 |
| `Home` `End` / `g` `G` | 跳到顶 / 底 |
| `←` / `h` | 收起目录；已收起则回到父目录 |
| `→` / `l` | 展开目录；已展开则下到第一个子项 |
| `Enter` | 切换光标所在目录的展开状态 |
| `[` `]` | 上一层 / 下一层 |
| `s` | 切换排序：按名字 ↔ 按体积（目录始终在前） |
| `Tab` / `Shift+Tab` | 焦点在树与详情之间循环 |
| `?` | 开关帮助浮层 |
| `q` / `Esc` / `Ctrl+C` | 退出（还原终端） |
| 左键点树行 | 选中该行，键盘焦点交给树 |
| 左键点详情 | 焦点交给详情 |
| 滚轮 | 滚鼠标**停着**的那块面板（树滚光标、详情滚视口），不必先点一下 |
| 右键点目录行 | 切展开态（与 `Enter` 同效） |

鼠标跟踪用 `Click` 模式（`tty.with_mouse`）：只收按下与滚轮，不收移动。
拖拽与框选不在范围内（见下文「非目标」）。

## 设计取舍

## 设计取舍

### 按列而不是按字符排版

CJK 占两列、组合字符零宽，`width.mbt` 把这件事钉住；
只按 `String::length` 排版，中文目录名会把整栏对齐带歪。

宽度按 grapheme cluster，不是按码点：一个 ZWJ 家族 emoji（`👨‍👩‍👧‍👦`）在终端里
只画一个字形、占 2 列，按码点相加会算成 8 列。`width.mbt` 先划 cluster，
簇的宽度由簇内第一个有宽度的码点定；`screen.mbt` 的格子因此存字符串，
一个 cluster 完整落进首格，截断只切在簇边界上。

自研 cluster 划分，只借零宽表：`kawaz/grapheme`（cluster）与
`moonbit-community/unicodewidth`（宽度）都不引——后者钉着 `x@0.4.44`，
与本仓 `x@0.5.5` 有收敛风险，引库也把「文本测量」这个可独立验收的点绑死在别人的版本上。
唯一借来的是零宽码点表：`scripts/gen_width_tables.py` 从 unicodewidth 的打包表
筛出 Mn/Me/Cf（Unicode 16.0），生成 `width_tables.mbt`，表落地后本仓不再依赖它。
cluster 划分取 UAX #29 里对宽度有影响的子集（GB9/GB9a/GB12/GB13），不做完整规则。

VS16 会把窄字抬成两列：`1` + VS16 + U+20E3（keycap）在终端里占 2 列，
簇宽在遇到 VS16 且当前为 1 列时会抬到 2 列。

### 边框用 ASCII

框线是 `+` `-` `|`，不是 Unicode 的圆角制表符：与「ASCII 一律一列」的口径一致，
也不会在某些终端字体下变成豆腐块。全屏下画框不是为了好看，是为了把
「这是应用」和「这是滚上去的 shell 输出」分开。

### 退出一定要还原

alternate screen 是独立缓冲区，正常退出回到主屏、原来的输出原封不动；
中途 panic / Ctrl+C / 任务取消则会把终端留在那一屏。两条保护：

1. tty 的 `with_raw_mode`（进全屏时也进 raw mode）
2. `AltScreen::leave` 的 `defer @async.protect_from_cancel`，且它是幂等的

`teardown_commands()` 把「退出要发什么」抽成纯函数并按顺序钉死：
复位样式 → 显示光标 → 离开 alternate screen。顺序不能换——
切换缓冲区会清屏并作用到主屏上。

### 焦点显式化

路径 A 只有一个能动的东西（树的光标），全屏下有两块会滚的面板，
键盘得先知道「这一下给谁」。焦点是 `Focus` 枚举（`Tree` / `Detail`），
顺序与循环在 `focus.mbt` 里纯函数化，可单测。

状态行与帮助浮层**不接焦点**：把 `Tab` 停在没有交互的面板上只会让人以为按键失灵。
窄屏下详情栏没有位置，但焦点留在它身上不算错——拉宽后面板会回来，焦点不该被拽走。

### 排序在源头做，不在视图里就地重排

`s` 要按体积重排。重排发生在**拍平那一步**
（`TreeView::from_tree_sorted`），不是在 `TreeView` 内部对 `all_rows` 就地排序：
`all_rows` 里每行带着 `depth`，折叠过滤靠「祖先在不在」判断，而
`nearest_visible`（光标所在子树被折叠后的落点）默认数组按路径有序。
数组一旦乱序，这两件事都要跟着改判断依据。排序只换行序，视图状态（光标、
折叠）重建后按路径回填，与换层同一套逻辑。

目录整体排在文件之前：目录自己不带大小，混在文件里按 0 排会全部沉底，
读起来像「目录都没了」。

### 不做样式

前景/背景/加粗本轮用不到，带上它会让「缓冲 diff」和「SGR 序列拼接」缠在一起。
`Screen` 只存字符串格子（一个 cluster 一格），焦点靠标题栏的 `>` 标记表达（不用反白），
要用色再加一层。

### 换层用回调注入

视图只管「光标在哪」，取另一层的树是数据源的事，键盘逻辑因此完全不依赖 `layer_tree`。

### 坐标反查和正查共用一份状态

鼠标落地要回答两个问题：「这个坐标落在哪块面板」和「面板里的第几行是哪一项」。
第二个问题的答案必须和渲染时用的**同一份** `offset` / `page_height`——
两套坐标就会点一行选到下一行。所以：

- 命中测试（`hit_test`）按 `Layout` 的**外框**判定：点边框也算点这块面板，
  否则边框成了一条「点不动的缝」
- 行号在 `tree_view.mbt` 里反查（`index_at_screen_row`），与 `draw_tree_pane`
  的 `offset + row` 严格互逆；测试里就按这条互逆关系钉住
- `app.mbt` 把「上一帧的布局」记在 `AppState.last_layout` 里再换算，而不是
  重新 `Layout::compute`：重算要终端尺寸，而鼠标处理是同步的、拿不到 async 的
  `window_size`；用画面上那一版也天然一致
- 点在空白格给 `None`，不夹到首行/末行——「点空白跳到底」不是任何人的直觉

### 拍平可见行

树是嵌套的、按键是线性的，每帧现算可见行既慢又难保证光标稳定；
一次性算出来，键盘只在数组上移动光标。

### 量化到可测的部分

- `layout.mbt` / `viewport.mbt` / `focus.mbt` / `alt_screen.mbt` 全是纯函数或纯状态
- `components.mbt` 只依赖 `Screen`，不碰终端
- `terminal_wbtest.mbt` 覆盖画布 diff 的几个判定（脏格、占位符、补齐）

真终端行为靠 `app.mbt` 的主循环在 CLI 冒烟里跑，不引入伪终端测试框架。

## 测试

```
moon test --target native -p tui
```

## 非目标

- 样式与配色
- 鼠标拖拽 / 框选（只接点击与滚轮）
- 边看边改（TUI 是只读视图，不产生镜像变更）
- 多标签 / 多镜像并列（一次只看一个镜像）
