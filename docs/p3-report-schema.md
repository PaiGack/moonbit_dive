# P3 报告 JSON schema

`image_analysis` 的 JSON 报告由 `report_to_json` / `report_to_json_string` 产出，
经 CLI 的 `-f json` 交给外部工具消费（信封形状见下文「CLI 的 `-f json` 出口」）。

- 顶层带 `schemaVersion`（当前 `2`），字段有增删改时递增
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
| `userBytes` | int | 用户写入的字节（**不含第 0 层**）；`userWastedPercent` 的分母 |
| `wastedBytes` | int | 浪费字节，口径 `Σ (cumulative - min)`，即 `Σ efficiency.paths` 里每行的 `size` |
| `userWastedPercent` | float | `wastedBytes / userBytes`，**分母不含 base image**（对齐 dive） |
| `wasted.overwritten` | int | 跨层重复写入浪费的字节 |
| `wasted.deleted` | int | whiteout / opaque 抹掉的字节 |

### `wastedBytes` 与 `wasted.*` 的口径差异

两个数都叫「浪费」但不是一回事，`wastedBytes` 才是 dive 同名出口的那个：

| 场景 | `wasted.overwritten`（真实丢掉的） | `wastedBytes`（`cumulative - min`） |
|---|---|---|
| 10 字节被 100 字节覆盖 | 10 | 90 |
| 10 字节被写成同样的 10 字节 | 10 | 10 |
| 被 whiteout 删掉 | 原大小 | 原大小（min 取 0） |
| 100 字节被 1 字节覆盖 | 100 | 1 |

`wastedBytes == cumulativeBytes - minBytes`，也就是逐路径效率表
（`--efficiency`）里每行 `size` 的合计。求和时别把两者混在一起。

**`userWastedPercent` 会超过 100%**：分子是整份 `wastedBytes`（含 base image 里
被覆盖的内容），分母只算用户层。base image 很大、用户只盖了几层时这就是常态，
dive 原版同样如此——它是「用户层的改动换来多少浪费」的相对指标，
不是「用户写的东西浪费了百分之几」。

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

一份手搓的两层镜像：L0 写 `/app/main.js`（10 字节），L1 把它改成 16 字节
并新增 `/app/other.js`（3 字节）。下面两段是从**同一份报告**出的两个渲染，
一个字节都不差——文本示例与 JSON 示例必须能对上，否则拿文本写解析脚本会踩坑。

文本（`render_text_report` 的原文，顺序即代码顺序）：

```
layers: 2
  L0: +2 ~0 -0 paths, wrote 10 bytes, wasted 0 bytes
  L1: +1 ~2 -0 paths, wrote 19 bytes, wasted 10 bytes
image:
  current: 19 bytes in 3 paths
  written: 29 bytes
  user written: 9 bytes (all layers but the base)
  wasted: 16 bytes (55.2%)
    by path (cumulative - min): 16 bytes
    overwritten: 10 bytes
    deleted: 0 bytes
  user wasted: 177.8% of 9 bytes
efficiency: 44.8% (13/29)
wasteful paths:
  10 bytes  x2  /app/main.js
largest directories:
  19 bytes  2 files  /app
```

JSON（`report_to_json_string`）：

```json
{
  "schemaVersion": 2,
  "layers": 2,
  "image": {
    "currentBytes": 19,
    "currentPaths": 3,
    "writtenBytes": 29,
    "userBytes": 9,
    "wastedBytes": 16,
    "userWastedPercent": 1.777778,
    "wasted": { "overwritten": 10, "deleted": 0 }
  },
  "efficiency": { "score": 0.448276, "minBytes": 13, "cumulativeBytes": 29 },
  "layerStats": [
    {
      "layer": 0,
      "addedPaths": 2,
      "overwrittenPaths": 0,
      "deletedPaths": 0,
      "writtenBytes": 10,
      "wastedBytes": 0,
      "erasedBytes": 0
    },
    {
      "layer": 1,
      "addedPaths": 1,
      "overwrittenPaths": 2,
      "deletedPaths": 0,
      "writtenBytes": 19,
      "wastedBytes": 10,
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
    { "path": "/app", "cumulativeBytes": 19, "files": 2 }
  ]
}
```

对读的几条锚：

| 文本 | JSON | 备注 |
|---|---|---|
| `wasted: 16 bytes (55.2%)` | `image.wastedBytes: 16` | 括号里的百分比 = `wastedBytes / writtenBytes = 16/29` |
| `by path (cumulative - min): 16 bytes` | 同上 | 文本多这一行只是把口径写在脸上，**不是**第二个数 |
| `overwritten: 10 bytes` / `deleted: 0 bytes` | `image.wasted.overwritten` / `.deleted` | 与 `wastedBytes` 不是一个数（见上「口径差异」） |
| `user wasted: 177.8% of 9 bytes` | `image.userWastedPercent: 1.777778` | 文本按百分数印、JSON 给 `0..n` 的比值 |
| `efficiency: 44.8% (13/29)` | `efficiency.score: 0.448276` + `minBytes`/`cumulativeBytes` | |
| `19 bytes  2 files  /app` | `largestDirectories[]` | 文本只印前 10 条，JSON 也只给 10 条 |

`layerStats[layer].wastedBytes` 是「这一层覆盖掉的旧内容」，与 `image.wastedBytes`
（`Σ cumulative - min`）同样不是一个口径：上例里 L1 的 10 就是我们多写的那 10 字节，
两者相等纯属巧合（一条路径只写了两版、第二版更大）。

## CLI 的 `-f json` 出口：体积报告 + 门禁判定

`dive <image> --no-tui --format json` 出的不是 `report_to_json` 裸奔，而是一个**信封**：

```json
{
  "schemaVersion": 2,          // = json_report_schema_version，体积报告的版本号
  "layers": 2,
  "image": { ... },
  "efficiency": { ... },
  "layerStats": [ ... ],
  "wastefulPaths": [ ... ],
  "largestDirectories": [ ... ],
  "source": "nginx:latest",     // 解析到的来源（路径 / 引用）
  "check": {                    // 门禁判定，即 CheckResult::to_json
    "source": "rules.json",     // 规则来源，与顶层 source（镜像来源）不是一回事
    "passed": true,
    "exitCode": 0,
    "summary": { "total": 1, "passed": 1, "failed": 0 },
    "rules": [ ... ]
  }
}
```

几条口径：

- 顶层字段**逐项**就是上面的体积报告（`schemaVersion` + `layers` + …），一个不少
- `image` 是体积概览，**不是**镜像名；来源挪到 `source`
- 判定整份进 `check`，字段与 `CheckResult::to_json` 一致，只少了两个：
  `version`（信封顶层已经有一个版本号，两个并存只会让消费方猜哪个管哪个）与
  `image`（它与顶层 `source` 是同一个入参，留着等于同一件事在报告里说两遍）
- 不给 `--rules` 时 `check` 是一份空判定（`total: 0`、`passed: true`），
  与 `-f text` 末尾那两行「0/0 rules passed」说的是同一件事
- 探针与脚本请按 `schemaVersion` 断版本、按 `image.wastedBytes` 之类的路径断数据，
  别再拿 `version == 1` 当「报告格式没变」

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
