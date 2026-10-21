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

### L4 模型层：详情面板的数从哪来（#72）

详情面板照 dive 的 `view/image_details.go` 排两段：上面是选中路径的账
（efficiency / wasted / total + 该路径的 versions / cumulative / min / overhead），
下面是整镜像的 inefficient files 表（`count / total space / path`）。

数字**不在这里算**：

| 面板上的东西 | 出处 |
|---|---|
| `efficiency` | `Report.efficiency.score()` |
| `wasted` | `image_analysis::wasted_bytes(report)`，即 `Σ (cumulative - min)`，dive 的口径 |
| 逐路径的 `versions` / `cumulative` / `min` | `EfficiencyReport.paths`（`Analysis::efficiency()`） |
| 下方那张表的行 | `Report::inefficient_paths`（= `efficiency_view_rows`，与 `--efficiency` 视图同源） |

早先那一版是 `cumulative = node_size * layers.length()` —— tar 层里没留历史大小，
注释自己认账「不假装精确」。现在逐路径版本表是分析阶段就填好的
（`VersionTable`），近似段整段删掉，面板与 CLI 的数字对得上。
`model_wbtest.mbt` 里有一条用例按「`Σ 表里的 size` == 面板的 `wasted`」钉住自洽。

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

界面是 `cmd/main` 的**默认出口**（issue #128 起的方案 B），不是新的子命令：
`dive <img>` 能开界面就开界面，`--no-tui` 才走文本。

退出码跟文本出口一个口径（`0/1/2`）：`--rules` 在界面里也是门禁，
交互看完一圈按 `q` 退出时照样判定。没有 `--rules` 时是 `0`，
运行错误是 `2`。

开关在界面里各有落点，一个都不能「被忽略」：

| 开关 | 界面里的意思 |
|---|---|
| `--layer N` | 起始层（缺省最后一层；越界点一句、夹回最后一层） |
| `--aggregate` | 起始档位就是 `Ctrl+A` 那档 |
| `--path P` | 树的光标落点（找不到就退到最近的可视祖先） |
| `--efficiency` | 详情面板顶到焦点，按多写空间那张表就在眼前 |
| `-f` / `-o` | 退出后把产物写出来（`-f text` 不写：报告已在眼前） |

终端判定在**进 alternate screen 之前**做：`stdin`/`stdout` 有一个不是 tty，
或者镜像是从 stdin 喂进来的（`dive - < img.tar`，界面会把 tar 流吃掉），
一律落回文本出口并在 stderr 点一句 `tui skipped: ...`。
`Tty::stdio()` 探不住这个——它只是把 fd 包一层，真正炸的是后面的
`with_raw_mode` 里的 `tcgetattr`，那时 `\e[?1049h` 已经发出去了。

全屏的进出由 `@tui.run_app` 自己管，`cmd/main` 只提供 raw mode 那一层保护。

## 两个比较档位（#69）

原版 dive 的 layer 面板有两个档位（`viewmodel.LayerCompareMode`）：`Ctrl+L` 看
「当前层相对上一层」，`Ctrl+A` 看「聚合」（累积）。本轮对齐它：

- `layer_tree`：`LayerView` 多一个 `aggregate` 字段与 `aggregate_changed_paths()`；
  `diff_aggregate` 按区间**累积**而不是两端点做一次快照比较——否则
  「第 0 层写过、第 2 层改回原样」的路径会被判成没动过
- `tui`：`CompareMode`（`Single` / `Aggregate`），`Ctrl+A` / `Ctrl+L` 切档；
  标题行写当前档位，状态行给删除条数，`d` 打开可滚动的删除列表
- `cmd/main`：`--aggregate` 换 `--layer` 视图的比较区间；文本单列一段
  `removed (not in the tree)`，JSON 多 `compare` / `aggregateBytes` 与 `diff.base`

`removed` 不进树：被删的路径已经不在树上，插「幽灵行」要动行模型、折叠判断与
光标落点，代价远大于收益。出口是「状态行计数 + `d` 的列表 + CLI 的一段文本」。

键位与 [#64](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/64) 的边界：
`Ctrl+A` 在这里是「layer 面板切聚合」（原版语义），filetree 面板那组
`Ctrl+A/R/M/U`（按状态过滤）属于 #64 的盘子，两边别各绑一个。

## 与 dive 键位表的差异说明（#70）

原版 dive 的键位集中在 `cmd/dive/cli/internal/ui/v1/key/config.go` 的
`DefaultBindings()`，每个动作是一个 `Config{Input: "up,k"}` 形态的字符串。
本轮把本仓 `keys.mbt` 的 `action_of_key` **逐条对齐**那张表：

| 作用域 | 动作 | 原版键 | 本仓 |
|---|---|---|---|
| Global | Quit | `ctrl+c` | 同（另保留 `q` / `Esc`） |
| Global | ToggleView | `tab` | 同（本仓只有树与详情两块，即切焦点） |
| Global | FilterFiles / CloseFilterFiles | `ctrl+f` / `esc` | **不做**，见下 |
| Navigation | Up/Down/Left/Right | `up,k` / `down,j` / `left,h` / `right,l` | 同 |
| Navigation | PageUp/PageDown | `pgup,u` / `pgdn,d` | 只做 `pgup`/`pgdn`/`u`；`d` 让给删除列表（#77），见下 |
| Layer | CompareAll | `ctrl+a` | 同（切聚合 diff 档位，与 #69 合流） |
| Layer | CompareLayer | `ctrl+l` | 同（切回当前层档） |
| Filetree | ToggleCollapseDir | `space` | 同（从原来的 `pgdn` 归位） |
| Filetree | ToggleAllCollapseDir | `ctrl+space` | 同 |
| Filetree | 过滤 added/removed/modified/unmodified | `ctrl+a/r/m/u` | 只做 `ctrl+u`（只看改写 ↔ 全都要），见下 |
| Filetree | ToggleShowAttributes | `ctrl+b` | **常显**，无开关 |
| Filetree | ToggleSortOrder | `ctrl+o` | 本仓用 `s`，`ctrl+o` 留空 |
| Filetree | 删除路径列表 | 原版无 | 本仓 `d`（#77） |

本仓原有的补充键（原版没有，按「只增不改」保留）：`q` / `Esc` 退出、
`[` `]` 换层、`g` `G` 到顶到底、`?` 帮助、`Enter` 折叠、`s` 排序。

### 三处必须说清楚的口径

**一、`Ctrl` 组合只认列出来的那几颗。** `Ctrl+M` 与 `Enter` 同码位（`0x0d`）、
`Ctrl+J` 与换行同码位——原版的 `ctrl+a/r/m/u` 里，`ctrl+m` 绑上就等于偷偷改了
`Enter`。本仓因此不认 `ctrl+m` / `ctrl+r` / `ctrl+j`，动作表里 `ctrl` 分支是一张
短白名单（`c` / `space` / `a` / `l` / `u`），其余一律 `None`。

**二、`Ctrl+Space` 在终端里是 NUL，tty 把它解成 `Char(' ')` + `ctrl`。**
这条**在真伪终端上实测过**（不是「按 `Char('\u{0}')` 推导」）：
`0x00` → `Char(' ') ctrl=true`、`0x20` → `Char(' ')` + 无修饰。
两个事件可区分，所以「`Space` 折叠一行、`Ctrl+Space` 全折叠」能共存。
`Ctrl+A/L/U` 同理落在 `0x01` / `0x0c` / `0x15` 上，tty 都归到小写字母 + `ctrl`。

顺带一个 **tty 上游的缺陷**（本仓不改，只记着）：把 `ESC` 单独先写、隔
`> esc_timeout_ms`（默认 50ms）再写 `[ B` 时，tty 的 `read_escape` 只回退
**一个**字节，开头那个 ESC 已被消费掉，于是解成「一个 `Escape` + 裸字符 `[` `B`」，
后面那颗真键丢了。三个字节同一次写入时正常解成 `Down`；普通终端的方向键
就是逐个原子写、帧间隔远大于 50ms，实测连按 `j j` / `↓↓` 都正常累积。

**三、`Ctrl+A` / `Ctrl+L` 与 #69 的比较档位合流。** 原版 `Ctrl+A` 是 Layer 作用域的
`CompareAll`（切「聚合」）、`Ctrl+L` 是 `CompareLayer`（切「当前层」）；本仓
[#69](#两个比较档位69) 已经把这两颗键绑成同一个语义（切 diff 档位），
因此本轮不再另立「以详情面板为承载面」的解释——**一颗键只有一个动作**。

**四、`d` 归删除列表，`u` 才是 `pgup` 的别名。** 原版导航里 `pgup,u` / `pgdn,d`
是两颗键各带一个字母别名。#77 先把 `d` 给了「被删除的路径」列表（它有独立浮层、
状态行计数与渲染），两个语义不可能同时挂在一颗键上——保留 #77 的 `d`，
翻页别名只留 `u`，`pgdn` 仍可用。

### 过滤只做一档，其余不绑

原版 `ctrl+a/r/m/u` 是把 added / removed / modified / unmodified 四棵拼起来的表
做过滤。本仓的树只有一棵（删除的路径**不在树上**，没有行可以给它上色，
`RowStatus` 也没有 `Removed`），所以：

- `Ctrl+U`（只看改写 ↔ 全都要）落地：**过滤态做成 `TreeView` 上的一个布尔**，
  而不是「另生成一棵只含某档的树」——错按了再按一次就复原，
  不会在状态里留下半棵拼出来的树。`set_filter` 自带「设成当前档 = 撤销」，
  与 dive 的 `InvertFilter` 同效，所以一颗键就能兼顾「只看改写」与「撤销」；
- `Ctrl+A`（只看新增）与 `Ctrl+R`（只看删除）**不绑**：前者与 Layer 作用域的
  `ctrl+a`（CompareAll）**同一个码位**，两者不可能同时绑在一颗键上；
  后者连数据都没有（没有行是「被删除」的）。少了两档之后，`TreeView::RowGroup`
  仍然留了三档枚举（added / modified / unchanged），`Row::in_group` 是它的唯一入口，
  将来真要补 `ctrl+r` 只需接上键盘那一格，不用改数据结构。

### `Ctrl+B` 常显，不做开关

原版 `Ctrl+B` 是开着/关掉「文件属性」这一栏。本仓把**权限 / mtime / 层号**
直接常显在详情面板里，理由有四条：

1. 详情面板本来就跟着光标走，属性是同一批「这一行是什么」的信息，
   再挂一个开关等于让同一块面板有两种内容；
2. 要多一层状态（面板高度、帮助文案、切换时的重排）才换得来「少看两行」；
3. 宽度够的地方本来就有位置，不够的地方（窄屏）详情栏整个不在，
   开关也救不回来；
4. `Ctrl+B` 这颗键因此空着——本仓不为了「把所有键都占满」而造动作。

`Row` 为此多带了 `mode` 与 `mtime`（数据源里本来就有，之前没带出来），
权限串由 `layer_tree::permission_string` 出，形态与 dive 的 `MetadataString` 一致
（`-rw-r--r--` / `drwxr-xr-x`）。**两处有意的偏差**：权限串的首字符只分
「目录 / 普通文件」（`Row` 只带 `is_dir`，链与硬链会显示成 `-`）；
`mtime` 按 **UTC** 换算成 `2023-11-14 22:13`，不查时区也不做相对时间——
详情面板要回答的是「两个路径谁写得更晚」，不需要本地时区。mtime 为 0
（数据源没记）时显示 `-`，不假装是 1970。

### 不做的两条

- **`Ctrl+F` 过滤 + `Esc` 关闭**：这是一整套 UI 状态（输入框 + 过滤态 + 焦点让位），
  不是一颗键。本仓的替代品是 `cmd/main --path`（前缀过滤子树）。
  真要做得单独立项，本轮不硬塞。
- **`Ctrl+E` 抽取文件到本地**：写文件系统，TUI 就不再是只读视图
  （与本文上面的非目标直接冲突）。

## 非目标

- 样式与配色（前景/背景/加粗）
- 鼠标拖拽 / 框选（点击与滚轮已接，见下）
- 边看边改（TUI 是只读视图，不产生镜像变更）
- 四档过滤里的「只看新增」「只看删除」（理由见上一节）
- `Ctrl+B` 的属性开关（属性常显，理由见上一节）

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

鼠标跟踪用 `Drag` 模式（#51 当时是 `Click`，见 #62 那节），与进出全屏配对：
`run_app` 里 `enable_mouse` / `disable_mouse` 一对 `defer`。漏关掉会让
**退出后的 shell** 把每次点击吐成一段 `\x1b[<...` 垃圾，所以关它排在切回主屏之前。

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

## 鼠标点击展开/折叠的调研（#62）

用户反馈「点击只能选中、点不开目录」。调研结论：不是没实现，而是**只在右键上**，
外加一条真终端上的隐患。详细方案见
[issue-62-mouse-click-fold-survey.md](issue-62-mouse-click-fold-survey.md)。

三点：

- 左键 `Select`、右键 `ToggleFold` 是 #51 的有意取舍（右键照 `dive` 直觉），
  但帮助浮层只写了右键，左键点目录「什么都不发生」很容易读成坏了
- `enable_mouse` 用的是 `Click`（`?1000h`）：只报按下/松开，没有「按住移动」档
- 样式层（kitty 键盘协议）会把鼠标报告升级成 `CSI <` 像素坐标扩展；tty 0.5.0
  的解析器只认 `CSI < cb ; col ; row M/m`，多出来的子参数一律判 `Unknown`，
  于是**开了该扩展的终端上整棵树都点不动**（连选中都没有）

候选方案：A 左键点目录即开合（推荐）；B 双击开合（要引状态，不推荐）；
C 只补提示（不解决问题）；D 配合 A，把跟踪模式换 `Drag` 并对 kitty 扩展做降级。

### 落地（A + D，C 顺手）

选的是 **A + D**，C 顺带；B 不做。改动收在两处：

- `TreeView::toggle_fold_at_screen_row`（`tree_view.mbt`）：坐标反查 + 落光标 +
  切展开态，左键与右键共用；`toggle` 对非目录行是空操作，所以
  「点目录开合、点文件只选中」是同一段代码
- `handle_mouse` 的 `Select` 分支改调它（`app.mbt`），右键那条也折成同一个函数
- `mouse_tracking_mode()`：默认 `Drag`（`?1002h`，比 `Click` 多一档「按住移动」）；
  像素鼠标终端上退到 `Motion`（那套要 any-event 才说话）
- `resolve_mouse(event, viewport_cols, viewport_rows)`：像素坐标 → 格子坐标。
  tty 0.5.0 的 `CSI <` 只认 `cb;col;row M/m`，kitty 那套的多余参数一律
  `Unknown`（本轮在 tty 源码 checkout 上实测过，不是纯推导）；
  折回格子后点击至少落在正确位置，不再整棵树点不动。
  换算贴边界时夹回视口内，宁可落点偏一点也不能点到屏幕外
- 帮助浮层那一行改成 `click  select; on a folder also fold / unfold`，
  右键那行保留（C）

验收口径（与调研一致）：

- 左键点目录开合、点文件只选中、右键不变、点空白与边框不动、
  折叠后再点回来光标仍停在目录行上
- 像素坐标能折回格子，且不越出视口
- `moon test --target native -p tui` 全绿（164 条）
