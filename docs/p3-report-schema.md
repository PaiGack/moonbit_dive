# P3 报告 JSON schema

`image_analysis` 的 JSON 报告由 `report_to_json` / `report_to_json_string` 产出，
用于 P4 的体积门禁判定与外部工具消费。

- 顶层带 `schemaVersion`（当前 `1`），字段有增删改时递增
- 所有字节数都是整数（`Int32`）
- 分数是 `0..1` 的浮点，输出保留 6 位小数，保证文本快照稳定
- 未提供块级阈值判定，门禁在 P4 的 `image_ci` 里做

## 顶层

| 字段 | 类型 | 说明 |
|---|---|---|
| `schemaVersion` | int | 结构版本号 |
| `layers` | int | 层数 |
| `image` | object | 体积概览，见下 |
| `efficiency` | object | 分数与分子分母 |
| `layerStats` | array | 每层统计，长度 = `layers` |
| `wastefulPaths` | array | 浪费最多的路径，最多 10 条 |
| `largestDirectories` | array | 占用最大的目录，最多 10 条 |

## `image`

| 字段 | 类型 | 说明 |
|---|---|---|
| `currentBytes` | int | 最后一层树上文件的字节合计 |
| `currentPaths` | int | 最后一层树上的路径数（文件、目录、链接都算） |
| `writtenBytes` | int | 累积写入字节 = `currentBytes` + 全部浪费 |
| `wasted.overwritten` | int | 跨层重复写入浪费的字节 |
| `wasted.deleted` | int | whiteout / opaque 抹掉的字节 |

## `efficiency`

| 字段 | 类型 | 说明 |
|---|---|---|
| `score` | float | `minBytes / cumulativeBytes`，无写入时 `1.0` |
| `minBytes` | int | Σ 各路径版本里最小的字节数 |
| `cumulativeBytes` | int | Σ 各路径所有版本的字节数 |

## `layerStats[]`

| 字段 | 类型 | 说明 |
|---|---|---|
| `layer` | int | 层下标，从 0 开始 |
| `addedPaths` | int | 本层新建的路径数 |
| `overwrittenPaths` | int | 本层改写的路径数 |
| `deletedPaths` | int | 本层删除的路径数（含子树） |
| `writtenBytes` | int | 本层写入的字节数 |
| `wastedBytes` | int | 本层覆盖掉的旧内容字节 |
| `erasedBytes` | int | 本层 opaque 抹掉的旧字节（不计入 `wastedBytes`） |

## `wastefulPaths[]`

| 字段 | 类型 | 说明 |
|---|---|---|
| `path` | string | 树内绝对路径 |
| `currentBytes` | int | 最后一版内容大小，被删则为 0 |
| `wastedBytes` | int | 这条路径失掉的字节 |
| `writes` | int | 被写入过几层 |
| `deleted` | bool | 是否被删除过 |
| `currentLayer` | int \| null | 当前内容来自哪一层，已删为 `null` |

## `largestDirectories[]`

| 字段 | 类型 | 说明 |
|---|---|---|
| `path` | string | 目录路径 |
| `cumulativeBytes` | int | 子树内文件字节合计 |
| `files` | int | 子树内文件数 |

## 示例

```json
{
  "schemaVersion": 1,
  "layers": 2,
  "image": {
    "currentBytes": 16,
    "currentPaths": 2,
    "writtenBytes": 26,
    "wasted": { "overwritten": 10, "deleted": 0 }
  },
  "efficiency": { "score": 0.384615, "minBytes": 10, "cumulativeBytes": 26 },
  "layerStats": [
    {
      "layer": 0,
      "addedPaths": 1,
      "overwrittenPaths": 0,
      "deletedPaths": 0,
      "writtenBytes": 10,
      "wastedBytes": 0,
      "erasedBytes": 0
    }
  ],
  "wastefulPaths": [
    {
      "path": "/app/main.js",
      "currentBytes": 16,
      "wastedBytes": 10,
      "writes": 2,
      "deleted": false,
      "currentLayer": 1
    }
  ],
  "largestDirectories": [
    { "path": "/app", "cumulativeBytes": 16, "files": 1 }
  ]
}
```

## `--efficiency` 视图的 JSON

`--efficiency` 是 CLI 的只读视图（不是整份报告的一部分），
由 `efficiency_view_to_json` 产出，结构版本号独立：
`efficiency_view_schema_version`（当前 `1`）。

字段与 `render_efficiency_view` 的文本逐项对齐。

| 字段 | 类型 | 说明 |
|---|---|---|
| `schemaVersion` | int | 视图结构版本号 |
| `efficiency` | object | 总分与分子分母，与顶层 `efficiency` 同构 |
| `path` | string \| null | 生效的 `--path` 前缀，未给为 `null` |
| `top` | int | 生效的条数上限；`-1` 表示不截断 |
| `metric` | string | 固定 `cumulativeMinusMin`，写明排序口径 |
| `paths` | array | 逐路径数组，见下 |

### `paths[]`

| 字段 | 类型 | 说明 |
|---|---|---|
| `path` | string | 树内绝对路径 |
| `versions` | int | 写了几版 |
| `cumulativeBytes` | int | 所有版本的字节数之和 |
| `minBytes` | int | 所有版本里最小的那个字节数 |
| `size` | int | `cumulativeBytes - minBytes`，排序键 |

### 与 `wastefulPaths[]` 的口径差异

两个榜都叫「浪费」，但不是同一个数，**不要混排**：

| | `wastefulPaths[].wastedBytes` | `paths[].size` |
|---|---|---|
| 口径 | 被覆盖 + 被删的实际字节 | 多写了几份（`cumulative - min`） |
| 同大小重写两次 | 第一份的字节数 | 等于单份大小 |
| 10 字节被 100 字节覆盖 | 10 | 10 |
| 100 字节被 1 字节覆盖 | 100 | 1 |
| 与总分的关系 | 无（分母是 `writtenBytes`） | 每行的 `cumulativeBytes` 之和 = 顶层 `cumulativeBytes` |

### 示例

```json
{
  "schemaVersion": 1,
  "efficiency": { "score": 0.016129, "minBytes": 28, "cumulativeBytes": 1736 },
  "path": null,
  "top": 10,
  "metric": "cumulativeMinusMin",
  "paths": [
    {
      "path": "/node_modules/pkg/index.js",
      "versions": 2,
      "cumulativeBytes": 1210,
      "minBytes": 10,
      "size": 1200
    }
  ]
}
```
