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

## 分层

```
screen.mbt      L0 按列×行的字符画布；写入即标脏，供增量重画
width.mbt       L0 显示宽度（CJK 占两列、组合字符零宽）与按列截断/补齐
terminal.mbt    L0 画布 → 终端字节流：首帧全量、之后只吐脏格
alt_screen.mbt  L0 alternate screen 的进/出序列，退出幂等、异常也还原
layout.mbt      L1 分栏布局引擎：面板矩形 + 边框 + 内容区 + 帮助浮层让位
viewport.mbt    L1 滚动视口：偏移 + 夹取，详情面板复用
components.mbt  L2 面板组件：画框、标题高亮、清内容区、溢出提示
tree_view.mbt   L2 树拍平成可上下走的行 + 展开/折叠 + 滚动 + 光标
render.mbt      L2 画一帧：标题、两块面板、状态行、帮助浮层
keys.mbt        L3 按键 → 动作；动作 → 视图状态（换层用回调注入）
focus.mbt       L3 焦点管理：顺序、循环、窄屏下的可见性
model.mbt       L4 把 image_analysis 的结果压成详情数据源（吃已解压的层）
app.mbt         L4 主循环：进全屏 → 取尺寸 → 组帧 → 等事件 → 退出还原
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
| `Tab` / `Shift+Tab` | 焦点在树与详情之间循环 |
| `?` | 开关帮助浮层 |
| `q` / `Esc` / `Ctrl+C` | 退出（还原终端） |

## 设计取舍

### 按列而不是按字符排版

CJK 占两列、组合字符零宽，`width.mbt` 把这件事钉住；
只按 `String::length` 排版，中文目录名会把整栏对齐带歪。

自研而不是引 `unicodewidth` / `grapheme`：本轮画面只要 ASCII + 常见 CJK，
引第三方会把「文本测量」这个本可独立验收的点绑死在别人的版本上。
真要做 grapheme cluster（ZWJ emoji 序列）再单开 issue 换实现——
接口只有 `display_width` / `char_width`，换起来不牵动画面代码。

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

### 不做样式

前景/背景/加粗本轮用不到，带上它会让「缓冲 diff」和「SGR 序列拼接」缠在一起。
`Screen` 只存字符，焦点靠标题栏的 `>` 标记表达（不用反白），要用色再加一层。

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
- 鼠标事件（tty 已解出，但本轮不接）
- grapheme cluster 级别的文本测量
- 边看边改（TUI 是只读视图，不产生镜像变更）
- 多标签 / 多镜像并列（一次只看一个镜像）
