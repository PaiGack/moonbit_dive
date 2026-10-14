# image_ci

把 P3 的体积分析变成 CI 里能用的**门禁**：声明式规则 + 明确退出码 + 可被流水线解析的注解。

参考 [dive](https://github.com/wagoodman/dive)（Go，MIT）的 `cmd/dive/cli/internal/ci/`，
但规则用 MoonBit 数据结构表达、从 JSON 加载，并补齐了 dive 没有的路径白/黑名单与
单文件上限。

## 快速开始

```moonbit check
///|
test "README example" {
  // 造一个两层镜像：/app/main.js 从 10 字节被覆盖成 16 字节
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
    @layer_tree.TarEntrySpec::Dir("node_modules"),
    @layer_tree.TarEntrySpec::File("node_modules/pkg/index.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
    @layer_tree.TarEntrySpec::File(
      "node_modules/pkg/index.js", "0123456789abcdefghij",
    ),
  ])

  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = [layer0, layer1]
  let analysis = @dive_analysis.analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }
  let report = @dive_analysis.build_report(analysis, tree)

  // 声明规则：大小上限 + 效率下限 + 拒绝 node_modules
  let ruleset = @image_ci.Ruleset::parse(
    (
      #|{ "rules": [
      #|  { "type": "maxImageSize", "maxBytes": 4096 },
      #|  { "type": "minEfficiency", "score": 0.5 },
      #|  { "type": "denyPaths", "patterns": ["/app/node_modules/**", "/node_modules/**"] }
      #|] }
    ),
  ) catch {
    err => fail(err.to_string())
  }

  let result = ruleset.check(report, tree, image="demo.tar")
  assert_eq(result.passed_count(), 1) // 只有大小上限过
  assert_eq(result.failed_count(), 2)
  assert_eq(@image_ci.exit_code_of(result), 1)
  // 命中的坏路径会原样报出来，CI 注解里能直接指认
  assert_true(result.results[2].locations[0].contains("node_modules"))
}
```

## 能力

| 能力 | 入口 |
|---|---|
| 规则集加载与校验 | `Ruleset::parse`、`Ruleset::of_rules`、`ConfigError` |
| 六类规则 | `RuleKind`（`MaxImageSize` / `MaxLayerSize` / `MaxWastedSize` / `MinEfficiency` / `DenyPaths` / `AllowPaths` / `MaxFileSize`） |
| 判定 | `Ruleset::check`、`CheckResult`、`RuleResult` |
| 路径模式 | `PathPattern::compile`、`PathPattern::matches`、`PathFilter` |
| 输出 | `CheckResult::to_text`、`to_json`、`to_annotations` |
| 退出码 | `exit_ok` / `exit_rule_failed` / `exit_config_error`、`exit_code_of` |
| 本地镜像输入 | `ImageSource::load`（docker save / OCI layout / 单层 tar / stdin） |

## 六类规则

| `type` | 参数 | 口径 |
|---|---|---|
| `maxImageSize` | `maxBytes` | 最后一层树上的文件字节合计 |
| `maxLayerSize` | `maxBytes` | 任意单层的写入字节，取最大值并指认层号 |
| `maxWastedSize` | `maxBytes` | 覆盖写入 + whiteout/opaque 抹掉的字节 |
| `minEfficiency` | `score` (`0..1`) | P3 的 `min / cumulative` |
| `denyPaths` | `patterns` | 命中即失败 |
| `allowPaths` | `patterns` | 名单外即失败 |
| `maxFileSize` | `maxBytes`、`scope` | 单文件，可限定目录子树 + 递归开关 |

输入 / 输出的完整字段见 [docs/p4-rules-schema.md](../docs/p4-rules-schema.md)。

## 退出码

```
0  全部规则通过
1  有规则未通过            —— 去改 Dockerfile
2  规则非法 / 镜像读不出来  —— 去改 rules.json 或流水线入参
```

1 和 2 分开是刻意的：看日志的人不用猜该动哪边。

## 命令行

```bash
# 只体检：打印 P3 报告 + 一句 gate 结论
moon run --target native cmd/main -- demo-image.tar

# 门禁：规则写在 rules.json 里
moon run --target native cmd/main -- demo-image.tar --rules rules.json

# 给 CI 消费
moon run --target native cmd/main -- demo-image.tar --rules rules.json --format json
moon run --target native cmd/main -- demo-image.tar --rules rules.json --format annotations

# 从 stdin 读（用重定向，不用管道）
moon run --target native cmd/main -- - --rules rules.json < demo-image.tar
```

输入按序自动识别：docker save 产物（`manifest.json` + `<层>/layer.tar`）、
OCI Image Layout 目录（`index.json` + `blobs/`）、单层 tar。

### 一个可复现的例子

仓库里的端到端测试（`image_ci/pipeline_test.mbt`）造的样例镜像：
两层，`/app/main.js` 与 `/node_modules/pkg/index.js` 各被覆盖一次。
写完规则跑出来的预期结果：

```
image: demo-image.tar
rules: rules.json
[pass] image-size: maxImageSize <= 4096 (observed 36 bytes, expected <= 4096 bytes)
[FAIL] efficiency: minEfficiency >= 0.5 (observed 35.7%, expected >= 50%)
        reason: efficiency 35.7% is below the 50% floor; 20 bytes were wasted across layers
[FAIL] no-node-modules: denyPaths 2 pattern(s) (observed 1 matching file(s), expected no file matches (/app/node_modules/**, /node_modules/**))
        reason: forbidden paths present: /node_modules/pkg/index.js
1/3 rules passed, 2 failed
gate: fail
```

退出码 `1`。`--format annotations` 会给出对应的 `::error` 行。

## 设计要点

- **只有两种结局，但要分得清**：规则「未通过」是镜像的问题，规则「非法」是配置的问题，
  两者退出码不同、输出的 JSON 结构也不同（配置错误带 `error` 字段、`rules` 为空）。
- **目录不算路径命中**：黑名单只看文件。否则一个 `/app/node_modules` 目录节点会把
  整棵子树都算成「命中」，报出来的现场反而看不清是哪几个文件。
- **模式语法保守**：只有 `*`（段内）与 `**`（跨段）两个通配符。够用，且实现能一眼看懂。
- **输入格式自动识别**：不要求用户说明是 docker save 还是 OCI layout，
  先看 tar 里有没有 `manifest.json`，没有就按单层 tar 处理。
- **层级解耦**：本包依赖 P3 的 `Report` 与 P2 的 `FileTree`，不反向依赖任何 CLI；
  `cmd/main` 只做接线。

## 已知限制

- 本地输入要能 seek：`ImageSource::load("-")` 走 `/dev/stdin`，
  管道（`|`）拿不到退出码，用重定向（`<`）或直接给文件路径。
- `moon run` 默认跑 wasm，拿不到退出码；要验证退出码用 `--target native`。
- 不做规则继承 / 组合 / 变量，一份 `rules.json` 就是一份平铺列表。

## 许可与出处

- 规则形态（`maxImageSize` / `maxLayerSize` / `maxEfficiency`、CI 输出与退出码）
  参考 dive 的 `cmd/dive/cli/internal/ci/`（MIT）
- 路径白/黑名单、`maxFileSize`、JSON 输入输出是本项目为 CI 场景补的
