///|
/// HTML 报告的快照与转义测试。
///
/// 快照钉的是「渲染结构」：字段全部来自 `Report`，与 JSON 报告的字段一一对应；
/// 改样式会动到快照，改字段会同时动到三份报告的测试，属于预期。
test "html report snapshots the whole picture" {
  let (tree, analysis) = report_fixture()
  let html = report_to_html(build_report(analysis, tree))
  // 结构上必须是一份自洽的 HTML 文档，且无外部依赖
  assert_true(html.has_prefix("<!DOCTYPE html>"))
  assert_true(html.has_suffix("</html>\n"))
  assert_true(!html.contains("<script"))
  assert_true(!html.contains("http://"))
  assert_true(!html.contains("https://"))
  assert_true(html.contains("<style>"))
  inspect(
    html,
    content=(
      #|<!DOCTYPE html>
      #|<html lang="en">
      #|<head>
      #|<meta charset="utf-8">
      #|<meta name="generator" content="dive">
      #|<title>dive image analysis</title>
      #|<style>body{margin:0;padding:24px;background:#11141a;color:#e6e9ef;font:14px/1.55 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}
      #|main{max-width:960px;margin:0 auto}
      #|h1{font-size:20px;margin:0 0 20px}
      #|h2{font-size:15px;margin:0 0 12px;color:#9aa4b2;font-weight:600}
      #|.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:20px}
      #|.card{background:#1a1f27;border:1px solid #262d38;border-radius:8px;padding:14px}
      #|.card-label{font-size:12px;color:#9aa4b2;text-transform:uppercase;letter-spacing:.04em}
      #|.card-value{font-size:24px;font-weight:600;margin:6px 0 2px}
      #|.card-hint{font-size:12px;color:#6f7a89}
      #|.panel{background:#1a1f27;border:1px solid #262d38;border-radius:8px;padding:16px;margin-bottom:20px}
      #|.bar{height:10px;background:#0d1015;border-radius:5px;overflow:hidden}
      #|.bar-fill{height:100%;background:linear-gradient(90deg,#3b82f6,#22c55e)}
      #|.fraction{margin:10px 0 0;font-variant-numeric:tabular-nums}
      #|.hint{margin:8px 0 0;font-size:12px;color:#6f7a89}
      #|table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
      #|th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #262d38}
      #|th{font-size:12px;color:#9aa4b2;font-weight:600}
      #|tbody tr:last-child td{border-bottom:none}
      #|.path{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;word-break:break-all}
      #|.empty{color:#6f7a89}
      #|</style>
      #|</head>
      #|<body>
      #|<main>
      #|<h1>image analysis</h1>
      #|<section class="cards">
      #|<div class="card">
      #|<div class="card-label">layers</div>
      #|<div class="card-value">3</div>
      #|</div>
      #|<div class="card">
      #|<div class="card-label">current</div>
      #|<div class="card-value">16 B</div>
      #|<div class="card-hint">2 paths on the final tree</div>
      #|</div>
      #|<div class="card">
      #|<div class="card-label">efficiency</div>
      #|<div class="card-value">32.3%</div>
      #|<div class="card-hint">min / cumulative</div>
      #|</div>
      #|<div class="card">
      #|<div class="card-label">wasted</div>
      #|<div class="card-value">48.4%</div>
      #|<div class="card-hint">15 B of 31 B written</div>
      #|</div>
      #|</section>
      #|<section class="panel">
      #|<h2>efficiency</h2>
      #|<div class="bar">
      #|<div class="bar-fill" style="width:32.3%"></div>
      #|</div>
      #|<p class="fraction">10 / 31 bytes (32.3%)</p>
      #|<p class="hint">score = sum(min_discovered) / sum(cumulative), aggregated per path across layers; wasted bytes are counted separately (see below).</p>
      #|</section>
      #|<section class="panel">
      #|<h2>layers</h2>
      #|<table>
      #|<thead><tr><th>layer</th><th>+paths</th><th>~paths</th><th>-paths</th><th>wrote</th><th>wasted</th><th>erased</th></tr></thead>
      #|<tbody>
      #|<tr><td>L0</td><td>3</td><td>0</td><td>0</td><td>15 B</td><td>0 B</td><td>0 B</td></tr>
      #|<tr><td>L1</td><td>0</td><td>1</td><td>0</td><td>16 B</td><td>10 B</td><td>0 B</td></tr>
      #|<tr><td>L2</td><td>0</td><td>0</td><td>1</td><td>0 B</td><td>5 B</td><td>0 B</td></tr>
      #|</tbody>
      #|</table>
      #|</section>
      #|<section class="panel">
      #|<h2>wasteful paths</h2>
      #|<table>
      #|<thead><tr><th>path</th><th>wasted</th><th>writes</th><th>state</th></tr></thead>
      #|<tbody>
      #|<tr><td class="path">/app/main.js</td><td>10 B</td><td>x2</td><td>L1</td></tr>
      #|<tr><td class="path">/app/README.md</td><td>5 B</td><td>x1</td><td>deleted</td></tr>
      #|</tbody>
      #|</table>
      #|</section>
      #|<section class="panel">
      #|<h2>largest directories</h2>
      #|<table>
      #|<thead><tr><th>path</th><th>size</th><th>files</th></tr></thead>
      #|<tbody>
      #|<tr><td class="path">/app</td><td>16 B</td><td>1</td></tr>
      #|</tbody>
      #|</table>
      #|</section>
      #|</main>
      #|</body>
      #|</html>
      #|
    ),
  )
}

///|
/// 特殊字符路径：`<`、`&`、引号必须转义，否则会撑破标签结构。
///
/// 这条路径同时出现在 wasteful paths 与 largest directories 两张表里，
/// 两处都得转义干净，且不许出现能当标签用的裸 `<`。
test "html report escapes paths in every table" {
  let (tree, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("a<b&c\"d"),
      @layer_tree.TarEntrySpec::File("a<b&c\"d/e'f>g", "0123456789"),
      @layer_tree.TarEntrySpec::File("a<b&c\"d/e'f>g", "0123456789abcdef"),
    ]),
  ])
  let html = report_to_html(build_report(analysis, tree))
  assert_true(html.contains("<td class=\"path\">/a&lt;b&amp;c&quot;d</td>"))
  assert_true(!html.contains("/a<b&c\"d"))
}

///|
/// 转义函数本身：`&` 必须最先换，否则 `&lt;` 会被二次转义成 `&amp;lt;`。
test "html escape covers the five characters" {
  assert_eq(html_escape("&<>\"'"), "&amp;&lt;&gt;&quot;&#39;")
  assert_eq(html_escape("a<b&c\"d"), "a&lt;b&amp;c&quot;d")
  assert_eq(html_escape("<"), "&lt;")
  assert_eq(html_escape("plain/path.js"), "plain/path.js")
}

///|
/// 空镜像：不该出现「0 条数据的空表」，而应有明确的 `(no layers)` / `(none)` 占位。
test "html report handles an empty image" {
  let (tree, analysis) = analyze_fixture([])
  let html = report_to_html(build_report(analysis, tree))
  assert_true(
    html.contains("<td colspan=\"7\" class=\"empty\">(no layers)</td>"),
  )
  assert_true(html.contains("<td colspan=\"4\" class=\"empty\">(none)</td>"))
  assert_true(html.contains("<td colspan=\"3\" class=\"empty\">(none)</td>"))
  assert_true(html.contains("<p class=\"fraction\">0 / 0 bytes (100%)</p>"))
  assert_true(!html.contains("<tbody>\n</tbody>"))
}

///|
/// 单层干净镜像：分数满分、进度条铺满、没有 wasteful paths。
test "html report handles a clean single layer image" {
  let (tree, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("bin"),
      @layer_tree.TarEntrySpec::File("bin/sh", "0123456789"),
    ]),
  ])
  let html = report_to_html(build_report(analysis, tree))
  assert_true(
    html.contains("<div class=\"bar-fill\" style=\"width:100%\"></div>"),
  )
  assert_true(html.contains("<p class=\"fraction\">10 / 10 bytes (100%)</p>"))
  assert_true(html.contains("<td>L0</td><td>2</td><td>0</td><td>0</td>"))
  assert_true(html.contains("<td colspan=\"4\" class=\"empty\">(none)</td>"))
}

///|
/// HTML 与 JSON 出自同一份 `Report`：字段逐一对应，不许两套口径。
test "html report keeps the same numbers as the json report" {
  let (tree, analysis) = report_fixture()
  let report = build_report(analysis, tree)
  let html = report_to_html(report)
  let json = report_to_json(report)
  let fields = match json {
    Json::Object(fields) => fields
    _ => fail("report must be a JSON object")
  }
  let image = match fields.get("image") {
    Some(Json::Object(image)) => image
    _ => fail("image must be an object")
  }
  let current = match image.get("currentBytes") {
    Some(value) if value is Json::Number(number, ..) => number.to_int()
    _ => fail("currentBytes must be a number")
  }
  let written = match image.get("writtenBytes") {
    Some(value) if value is Json::Number(number, ..) => number.to_int()
    _ => fail("writtenBytes must be a number")
  }
  assert_true(html.contains("<div class=\"card-value\">\{current} B</div>"))
  assert_true(
    html.contains(
      "\{report.efficiency.min_bytes} / \{report.efficiency.cumulative_bytes} bytes",
    ),
  )
  assert_true(html.contains("of \{written} B written"))
  for usage in report.usages {
    assert_true(
      html.contains(
        "<td>L\{usage.layer}</td><td>\{usage.added_paths}</td><td>\{usage.overwritten_paths}</td><td>\{usage.deleted_paths}</td>",
      ),
    )
  }
}
