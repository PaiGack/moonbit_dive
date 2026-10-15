# 聚合 vs 当前层：比较档位的落地（#69）

[#69](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/69) 要给 TUI / CLI 补
「聚合 vs 当前层」的 diff 档位，对齐原版 dive 的 `Ctrl+A` / `Ctrl+L`。本文记录落地口径。

## 一、原版是什么

dive 的 `LayerSetState::GetCompareIndexes` 切档位时换的是**比较区间的四个下标**，
树本身只有一棵：

```go
if state.CompareMode == CompareSingleLayer {
    bottomTreeStop = state.LayerIndex - 1; topTreeStart = state.LayerIndex  // [0,n-1] vs [n,n]
} else {
    bottomTreeStop = state.CompareStartIndex; topTreeStart = state.CompareStartIndex + 1
}
```

渲染时把底树叠成一棵、逐层 `CompareAndMark` 标 diff，因此聚合视图 =
「这段区间整体变了什么」，且**被后续层改回的路径也算 `Modified`**。

## 二、落地口径

### 聚合 diff 不是「两端点做一次快照比较」

最直观的写法是「用第 `base` 层的 tree 与第 `n` 层的 tree 做一次 `diff_snapshots`」，
但那样得不到验收要的那条：`diff_snapshots` 比的是节点的**大小与类型**，
「第 0 层写过、第 2 层改回原样」的路径在两个端点上字节一样，会被判成没动过。

所以按区间**累积**（`diff_aggregate`）：

1. 取区间内各层 diff 里被碰过的全部路径（`added` / `modified` / `removed` 的并集）
2. 按两端的树归类：只在终点 -> `added`，两头都在 -> `modified`，只在起点 -> `removed`
3. 区间内碰过、最后两头都不在的路径丢掉——视图画的是终点的树，没有行可以落
4. 没被直接碰过、但子树里有改动的目录并入 `modified`（对齐 `deriveDiffType` 的父目录合并）
5. 若直接改过，按归类走

### 比较区间的起点

- `layer == 0`：起点是**空树**（第 0 层之前），区间 `[0, 0]`
- `layer >= 1`：起点是**第 0 层的树**，区间 `[1, layer]`

后者与 dive 的默认 `CompareStartIndex = 0` 对齐；本仓没有「移动聚合起点」的控件，
所以起点固定。第 0 层自身用空树是唯一说得通的退化：让它去跟第 0 层自己比恒为空。

### 父目录合并的两处差别（刻意的）

| | 逐层 `diff`（既有） | 聚合 `aggregate`（本轮） |
|---|---|---|
| 判据 | 节点的大小与类型 | 区间内「碰过」 |
| 目录行 | 恒不上色（目录大小恒为 0） | 子树有改动即 `modified` |
| 改回原样 | 不算动过 | 算 `modified` |

逐层口径一个字都没动：它是既有 API，改它会牵动 `changed_paths` / `render_diff` /
`image_analysis` 的既有快照。聚合档是**新字段**，只在新档位下被使用。

### 体积差与 diff 不是同一把尺子

`LayerView::aggregate_size_delta(base)` 是**端点差**：终点的树减去起点的树。
它和聚合 diff 的「碰过即算」口径不同——被改回原样的路径在 diff 里是 `modified`，
在体积差里贡献 0。CLI 的 JSON 里它叫 `aggregateBytes`，别拿它去印证 `diff`。

## 三、`removed` 的出口

聚合档下 `removed` 可能有几百条，而它们**不在终点的树上**。两条路：

- a) 视图只显示 `+ / ~`，删除单独给一张列表
- b) 在树里为被删路径造「幽灵行」

选 **a**。幽灵行要动行模型（`Row` 得能表示「树上没有这条」）、折叠判断
（祖先关系怎么算）、光标落点（选中一条不存在的路径意味着什么），
代价远大于收益；而列表加一个计数就能把「少了什么」说清楚。

出口有三处：

- 状态行右侧的 `N removed`（当前档位的计数）
- TUI 的 `d`：可滚动列表，路径染红
- CLI 的 `--aggregate`：文本多一段 `removed (not in the tree)`，JSON 里就是 `diff.removed`

## 四、验收对照

| 验收项 | 落点 |
|---|---|
| 两档可切换，切档后树形状不变、只有标注变 | `AppState::switch_compare_mode`；用例 `switching the compare mode keeps the tree and only re-colours` |
| 「第 0 层写过、第 2 层改回原样」标 `Modified` | `diff_aggregate`；用例 `aggregate diff marks a path rewritten back as modified`（`layer_tree` 与 README 各一） |
| `removed` 有明确出口并写进 README | 状态行计数 + `d` 列表 + CLI 一段；`tui/README.mbt.md` 的「两个比较档位」 |
| `cmd/main` 有只读开关，输出可快照，不给开关行为不变 | `--aggregate`；用例 `aggregate flag switches the compare range of the layer view` / `the layer view is unchanged without the aggregate flag` |
| 不加新依赖，`moon test --target native` 全绿 | 无新依赖；全量测试见 CI |

## 五、未做

- 移动聚合起点（dive 的 `CompareStartIndex` 可上下移）：本仓没有对应控件，
  起点固定第 0 层
- filetree 面板的按状态过滤（`Ctrl+A/R/M/U`）：属 #64
- 跨层时间线（`--all-layers`）：属 #27 的另一条增量
