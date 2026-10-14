# P4 门禁输入与输出 schema

`image_ci` 有两份机器可读的 JSON：**输入**（规则 DSL，`rules.json`）与
**输出**（判定结论，stdout）。两份都带 `version` / `schemaVersion`，
字段有增删改时递增。

判定结论里的数字口径来自 P3 的[报告 schema](p3-report-schema.md)，
本文只说明门禁自己新增的部分。

## 输入：rules.json

顶层是一个对象，字段：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `version` | int | 否 | 保留字段，当前只接受 `1`（缺失按 1 处理） |
| `ids` | string[] | 否 | 按顺序给每条规则命名，长度不足时后面的规则回退到 `rule-N` |
| `rules` | array | 是 | 非空；见下 |

`rules[i]` 的公共字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | 规则种类，见下表 |
| `id` | string | 可选；优先级低于顶层 `ids`，缺省 `rule-<i+1>` |

### 六类规则

| `type` | 参数 | 含义 |
|---|---|---|
| `maxImageSize` | `maxBytes` (int, 必填) | 镜像当前占用 ≤ 上限 |
| `maxLayerSize` | `maxBytes` (int, 必填) | 任意单层的写入字节 ≤ 上限 |
| `maxWastedSize` | `maxBytes` (int, 必填) | 覆盖写入 + 被删除的字节 ≤ 上限 |
| `minEfficiency` | `score` (float, 必填, `0..1`) | efficiency score ≥ 下限 |
| `denyPaths` | `patterns` (string[], 必填非空) | 命中的文件即失败 |
| `allowPaths` | `patterns` (string[], 必填非空) | 白名单外的文件即失败 |
| `maxFileSize` | `maxBytes` (int, 必填)、`scope` (可选) | 单个文件字节 ≤ 上限 |

`maxFileSize.scope` 限定检查范围：

```json
{ "path": "/usr/**", "recursive": true }
```

- `path` 必填，走下面的路径模式语法
- `recursive` 缺省 `true`；`false` 表示只看 `path` 的直接子项
- 不带 `scope` 表示整镜像

### 路径模式语法

大小写敏感，匹配的是树内绝对路径（`/usr/bin/sh`），相对写法会补前导 `/`：

| 写法 | 含义 |
|---|---|
| `/a/b` | 恰好这一段路径 |
| `/a/*` | `/a` 下任意一个直接子项（`*` 只在段内通配） |
| `/a/*.log` | 段内前缀/后缀/中缀通配 |
| `/a/**` | `/a` 整个子树（`**` 吃掉任意多段，含零段） |
| `/a/**/cache` | `/a` 下任意深度的 `cache` |
| `/a/` | 等价于 `/a/**` |
| `a/b` | 等价于 `/a/b` |

目录本身不算命中，只看文件（否则一个目录会把整棵子树拖下水）。

### 非法规则

以下情况一律按「规则非法」处理（CLI exit code 2），不做任何判定：

- JSON 解析失败、顶层不是对象
- 缺 `rules` 或 `rules` 为空
- `rules[i]` 不是对象、`type` 未知
- 数字字段类型不对、为负、超出 i32
- `score` 不在 `0..1`
- `patterns` 为空或含非字符串
- `scope.path` 缺失 / 为空、`scope` 不是对象

### 示例

```json
{
  "ids": ["image-size", "efficiency", "no-node-modules"],
  "rules": [
    { "type": "maxImageSize", "maxBytes": 104857600 },
    { "type": "minEfficiency", "score": 0.8 },
    { "type": "denyPaths", "patterns": ["/app/node_modules/**"] },
    { "type": "maxFileSize", "maxBytes": 10485760, "scope": { "path": "/var/log/**" } }
  ]
}
```

## 输出：判定结论

`dive --format json` 或 `CheckResult::to_json` 产出：

| 字段 | 类型 | 说明 |
|---|---|---|
| `version` | int | 结论结构版本，当前 `1` |
| `source` | string | 规则来源（文件路径 / `<inline>`） |
| `image` | string | 被检查的镜像（文件路径 / `<stdin>`） |
| `passed` | bool | 是否全部规则通过 |
| `exitCode` | int | 进程应返回的退出码 |
| `summary` | object | `total` / `passed` / `failed` |
| `rules` | array | 每条规则的结论，顺序与输入一致 |

`rules[i]`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 规则 id |
| `type` | string | 与输入的 `type` 一致，便于对号入座 |
| `rule` | string | 规则的人话形式 |
| `status` | `"pass"` \| `"fail"` | 结论 |
| `observed` | string | 实测值的人话形式 |
| `expected` | string | 阈值的人话形式 |
| `reason` | string | 失败原因；通过时为空串 |
| `locations` | string[] | 现场路径（最多 10 条），失败时用来定位 |

### 配置错误的输出

规则非法时也走 `--format json`，给出一份可解析的兜底结构——
CI 里同一个解析器能读，不用为「配置错」单独写分支：

```json
{
  "version": 1,
  "source": "rules.json",
  "image": "",
  "passed": false,
  "exitCode": 2,
  "error": "cannot parse rules json: Invalid character 'o' at line 1, column 1",
  "summary": { "total": 0, "passed": 0, "failed": 0 },
  "rules": []
}
```

## 退出码

| code | 含义 | 该去改什么 |
|---|---|---|
| 0 | 全部规则通过 | 没事 |
| 1 | 有规则未通过 | Dockerfile / 镜像构建 |
| 2 | 规则非法，或镜像读不出来、跑不通分析 | rules.json / 流水线入参 |

1 与 2 分开是为了让人看日志的第一眼就知道该改哪个文件。

## CI 注解

`dive --format annotations` 输出 GitHub Actions / GitLab 可解析的形式：

```
::error file=<image>,title=image-size::image-size: maxImageSize <= 104857600 — observed 209715200 bytes exceeds the 104857600 bytes limit by 104857600 bytes (observed 209715200 bytes, expected <= 104857600 bytes)
::error title=image-size-gate::1/3 rules failed
```

- 通过的规则出 `::notice`，未通过出 `::error`
- `title` 用规则 id，`file` 固定为 `<image>`（镜像里的路径不是工作区文件）
- 消息里的 `%` / 换行按 GitHub 规则转义
