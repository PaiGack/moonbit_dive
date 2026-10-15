# tui

[dive](https://github.com/wagoodman/dive)（Go，MIT）的**交互式看树**在 MoonBit 上的实现：
在终端里上下走文件树、折叠目录、左右切层，右侧跟一张选中路径的体积详情。
底层用 [`moonbit-community/tty`](https://moonbitlang.github.io/mooncakes/moonbit-community/tty/)
做终端原语（raw mode / 尺寸 / 输入解码 / 光标与擦除）。

定位是 [#27](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/27) 里说的
**路径 A：非全屏交互式看树**——占主屏、底部一行状态条，
不切 alternate screen、不做分栏布局引擎。全屏形态（路径 B）另议，见
[#46](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/46) 的分层倒排。

## 分层

```
screen.mbt      L0 按列×行的字符画布；写入即标脏，供增量重画
width.mbt       L0 显示宽度（CJK 占两列、组合字符零宽）与按列截断/补齐
terminal.mbt    L0 画布 → 终端字节流：首帧全量、之后只吐脏格
layout.mbt      L1 一帧的分栏（标题 / 左右主体 / 状态行），窄屏退化单栏
tree_view.mbt   L2 树拍平成可上下走的行 + 展开/折叠 + 滚动 + 光标
render.mbt      L2 画一帧：标题、树、详情面板、状态行
keys.mbt        L3 按键 → 动作；动作 → 视图状态（换层用回调注入）
model.mbt       L4 把 image_analysis 的结果压成详情数据源（吃已解压的层）
app.mbt         L4 主循环：取尺寸 → 组帧 → 等事件
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

  // 建视图状态：默认看第 0 层
  let state = @tui.AppState::new(views, None, "demo:latest")
  assert_eq(state.view.layer, 0)
  assert_eq(state.view.visible.length(), 2)

  // 走行 + 折叠 + 换层
  state.view.move_down()
  assert_eq(state.view.cursor, 1)
  state.view.move_to(state.view.index_of_path("/app").unwrap())
  state.view.toggle()
  assert_true(state.view.collapsed.contains("/app"))
  state.switch_layer(1)
  assert_eq(state.view.layer, 1)
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

按键：

| 键 | 动作 |
|---|---|
| `↑` `↓` / `k` `j` | 上下走行 |
| `PgUp` `PgDn` / `b` `Space` | 翻页 |
| `Home` `End` / `g` `G` | 跳到顶 / 底 |
| `←` / `h` | 收起目录；已收起则回到父目录 |
| `→` / `l` | 展开目录；已展开则下到第一个子项 |
| `Enter` / `Tab` | 切换光标所在目录的展开状态 |
| `[` `]` | 上一层 / 下一层 |
| `q` / `Esc` / `Ctrl+C` | 退出 |

## 设计取舍

- **按列而不是按字符排版**：CJK 占两列、组合字符零宽，`width.mbt` 把这件事钉住；
  只按 `String::length` 排版，中文目录名会把整栏对齐带歪。
- **自研宽度而不是引 `unicodewidth` / `grapheme`**：本轮画面只要 ASCII + 常见 CJK，
  引第三方会把「文本测量」这个本可独立验收的点绑死在别人的版本上。
  真要做 grapheme cluster（ZWJ emoji 序列）再单开 issue 换实现——
  接口只有 `display_width` / `char_width`，换起来不牵动画面代码。
- **不做样式（前景/背景/加粗）**：本轮用不到，带上它会让「缓冲 diff」和
  「SGR 序列拼接」缠在一起。要用色再加一层。
- **换层用回调注入**：视图只管「光标在哪」，取另一层的树是数据源的事，
  键盘逻辑因此完全不依赖 `layer_tree`。
- **拍平可见行**：树是嵌套的、按键是线性的，每帧现算可见行既慢又难保证光标稳定；
  一次性算出来，键盘只在数组上移动光标。

## 测试

```
moon test --target native -p tui
```

`screen` / `width` / `layout` / `tree_view` / `keys` / `render` 全是纯函数或纯状态，
单测不碰终端；`terminal_wbtest.mbt` 覆盖画布 diff 的几个判定（脏格、占位符、补齐）。
真终端行为靠 `app.mbt` 的主循环在 CLI 冒烟里跑，不引入伪终端测试框架。
