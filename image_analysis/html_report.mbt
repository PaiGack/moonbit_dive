///|
/// HTML 报告的渲染：与 `render_text_report` / `report_to_json` 并列的第三种后端，
/// 数据全部来自同一个 `Report`，不在这里重算任何口径。
///
/// 形态是「单文件、无外部依赖、双击即看」：内联一段 `<style>`，没有 JS，
/// 不做交互（层展开留给 TUI，见 issue #26）。
///
/// 所有插值都过 `html_escape`：路径名与镜像名都是外部输入，`<`、`&`、引号
/// 必须转义，否则一个文件名叫 `a<b` 就能把结构撑破。
pub fn report_to_html(report : Report) -> String {
  let builder = StringBuilder()
  builder.write_string("<!DOCTYPE html>\n")
  builder.write_string("<html lang=\"en\">\n")
  builder.write_string("<head>\n")
  builder.write_string("<meta charset=\"utf-8\">\n")
  builder.write_string("<meta name=\"generator\" content=\"dive\">\n")
  builder.write_string("<title>dive image analysis</title>\n")
  builder.write_string("<style>\{html_report_style()}</style>\n")
  builder.write_string("</head>\n")
  builder.write_string("<body>\n")
  builder.write_string("<main>\n")
  builder.write_string("<h1>image analysis</h1>\n")
  builder.write_string(render_overview_cards(report))
  builder.write_string(render_efficiency_card(report))
  builder.write_string(render_layer_table(report))
  builder.write_string(render_wasteful_table(report))
  builder.write_string(render_hotspot_table(report))
  builder.write_string("</main>\n")
  builder.write_string("</body>\n")
  builder.write_string("</html>\n")
  builder.to_string()
}

///|
/// 顶部概览卡：层数 / current bytes / efficiency 分数 / wasted 占比。
fn render_overview_cards(report : Report) -> String {
  let wasted = report.overwritten_wasted + report.deleted_wasted
  let builder = StringBuilder()
  builder.write_string("<section class=\"cards\">\n")
  builder.write_string(card("layers", report.layers.to_string(), ""))
  builder.write_string(
    card(
      "current",
      "\{report.final_file_bytes} B",
      "\{report.final_paths} paths on the final tree",
    ),
  )
  builder.write_string(
    card("efficiency", percent(report.efficiency.score()), "min / cumulative"),
  )
  builder.write_string(
    card(
      "wasted",
      percent(wasted_ratio(report)),
      "\{wasted} B of \{report.total_bytes} B written",
    ),
  )
  builder.write_string("</section>\n")
  builder.to_string()
}

///|
/// 单张概览卡。`value` 与 `hint` 都是我们自己拼出来的数字 / 固定文案，
/// 但仍然统一转义，免得以后有人往里塞路径。
fn card(label : String, value : String, hint : String) -> String {
  let builder = StringBuilder()
  builder.write_string("<div class=\"card\">\n")
  builder.write_string(
    "<div class=\"card-label\">\{html_escape(label)}</div>\n",
  )
  builder.write_string(
    "<div class=\"card-value\">\{html_escape(value)}</div>\n",
  )
  if hint != "" {
    builder.write_string(
      "<div class=\"card-hint\">\{html_escape(hint)}</div>\n",
    )
  }
  builder.write_string("</div>\n")
  builder.to_string()
}

///|
/// efficiency 区块：进度条 + min/cumulative 分子分母明示。
fn render_efficiency_card(report : Report) -> String {
  let score = report.efficiency.score()
  let builder = StringBuilder()
  builder.write_string("<section class=\"panel\">\n")
  builder.write_string("<h2>efficiency</h2>\n")
  builder.write_string("<div class=\"bar\">\n")
  builder.write_string(bar_fill(score))
  builder.write_string("</div>\n")
  builder.write_string(
    "<p class=\"fraction\">\{report.efficiency.min_bytes} / \{report.efficiency.cumulative_bytes} bytes (\{percent(score)})</p>\n",
  )
  builder.write_string(
    "<p class=\"hint\">score = sum(min_discovered) / sum(cumulative), aggregated per path across layers; wasted bytes are counted separately (see below).</p>\n",
  )
  builder.write_string("</section>\n")
  builder.to_string()
}

///|
/// 进度条填充部分：宽度按分数取整百分比，限制在 `0%..100%`。
fn bar_fill(score : Double) -> String {
  let clamped = if score < 0.0 {
    0.0
  } else if score > 1.0 {
    1.0
  } else {
    score
  }
  let width = (clamped * 1000.0).round() / 10.0
  "<div class=\"bar-fill\" style=\"width:\{width}%\"></div>\n"
}

///|
/// 逐层表：`+a ~o -d` 路径数、wrote / wasted / erased 字节。
fn render_layer_table(report : Report) -> String {
  let builder = StringBuilder()
  builder.write_string("<section class=\"panel\">\n")
  builder.write_string("<h2>layers</h2>\n")
  builder.write_string("<table>\n")
  builder.write_string(
    "<thead><tr><th>layer</th><th>+paths</th><th>~paths</th><th>-paths</th><th>wrote</th><th>wasted</th><th>erased</th></tr></thead>\n",
  )
  builder.write_string("<tbody>\n")
  if report.usages.is_empty() {
    builder.write_string(
      "<tr><td colspan=\"7\" class=\"empty\">(no layers)</td></tr>\n",
    )
  } else {
    for usage in report.usages {
      builder.write_string(
        "<tr><td>L\{usage.layer}</td><td>\{usage.added_paths}</td><td>\{usage.overwritten_paths}</td><td>\{usage.deleted_paths}</td><td>\{usage.written_bytes} B</td><td>\{usage.wasted_bytes} B</td><td>\{usage.erased_bytes} B</td></tr>\n",
      )
    }
  }
  builder.write_string("</tbody>\n")
  builder.write_string("</table>\n")
  builder.write_string("</section>\n")
  builder.to_string()
}

///|
/// wasteful paths 表：浪费最多的路径，含 writes 与当前层。
fn render_wasteful_table(report : Report) -> String {
  let builder = StringBuilder()
  builder.write_string("<section class=\"panel\">\n")
  builder.write_string("<h2>wasteful paths</h2>\n")
  builder.write_string("<table>\n")
  builder.write_string(
    "<thead><tr><th>path</th><th>wasted</th><th>writes</th><th>state</th></tr></thead>\n",
  )
  builder.write_string("<tbody>\n")
  if report.wasteful_paths.is_empty() {
    builder.write_string(
      "<tr><td colspan=\"4\" class=\"empty\">(none)</td></tr>\n",
    )
  } else {
    for size in report.wasteful_paths {
      let state = match size.current_layer {
        Some(layer) => "L\{layer}"
        None => "deleted"
      }
      builder.write_string(
        "<tr><td class=\"path\">\{html_escape(size.path)}</td><td>\{size.wasted_bytes} B</td><td>x\{size.writes}</td><td>\{html_escape(state)}</td></tr>\n",
      )
    }
  }
  builder.write_string("</tbody>\n")
  builder.write_string("</table>\n")
  builder.write_string("</section>\n")
  builder.to_string()
}

///|
/// largest directories 表：占用最大的目录子树。
fn render_hotspot_table(report : Report) -> String {
  let builder = StringBuilder()
  builder.write_string("<section class=\"panel\">\n")
  builder.write_string("<h2>largest directories</h2>\n")
  builder.write_string("<table>\n")
  builder.write_string(
    "<thead><tr><th>path</th><th>size</th><th>files</th></tr></thead>\n",
  )
  builder.write_string("<tbody>\n")
  if report.hotspots.is_empty() {
    builder.write_string(
      "<tr><td colspan=\"3\" class=\"empty\">(none)</td></tr>\n",
    )
  } else {
    for spot in report.hotspots {
      builder.write_string(
        "<tr><td class=\"path\">\{html_escape(spot.path)}</td><td>\{spot.cumulative_bytes} B</td><td>\{spot.files}</td></tr>\n",
      )
    }
  }
  builder.write_string("</tbody>\n")
  builder.write_string("</table>\n")
  builder.write_string("</section>\n")
  builder.to_string()
}

///|
/// HTML 文本转义：`&` 必须第一个换，否则会把后面转义出来的实体再转一遍。
///
/// 覆盖 `& < > " '` 五个字符，够用于文本节点与属性值（这里只用在文本节点）。
pub fn html_escape(text : String) -> String {
  let builder = StringBuilder()
  for unit in text {
    match unit {
      '&' => builder.write_string("&amp;")
      '<' => builder.write_string("&lt;")
      '>' => builder.write_string("&gt;")
      '"' => builder.write_string("&quot;")
      '\'' => builder.write_string("&#39;")
      _ => builder.write_char(unit)
    }
  }
  builder.to_string()
}

///|
/// 内联样式：没有 CSS 框架，也不引外部文件，双击就能看。
fn html_report_style() -> String {
  "body{margin:0;padding:24px;background:#11141a;color:#e6e9ef;font:14px/1.55 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}\n" +
  "main{max-width:960px;margin:0 auto}\n" +
  "h1{font-size:20px;margin:0 0 20px}\n" +
  "h2{font-size:15px;margin:0 0 12px;color:#9aa4b2;font-weight:600}\n" +
  ".cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:20px}\n" +
  ".card{background:#1a1f27;border:1px solid #262d38;border-radius:8px;padding:14px}\n" +
  ".card-label{font-size:12px;color:#9aa4b2;text-transform:uppercase;letter-spacing:.04em}\n" +
  ".card-value{font-size:24px;font-weight:600;margin:6px 0 2px}\n" +
  ".card-hint{font-size:12px;color:#6f7a89}\n" +
  ".panel{background:#1a1f27;border:1px solid #262d38;border-radius:8px;padding:16px;margin-bottom:20px}\n" +
  ".bar{height:10px;background:#0d1015;border-radius:5px;overflow:hidden}\n" +
  ".bar-fill{height:100%;background:linear-gradient(90deg,#3b82f6,#22c55e)}\n" +
  ".fraction{margin:10px 0 0;font-variant-numeric:tabular-nums}\n" +
  ".hint{margin:8px 0 0;font-size:12px;color:#6f7a89}\n" +
  "table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}\n" +
  "th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #262d38}\n" +
  "th{font-size:12px;color:#9aa4b2;font-weight:600}\n" +
  "tbody tr:last-child td{border-bottom:none}\n" +
  ".path{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;word-break:break-all}\n" +
  ".empty{color:#6f7a89}\n"
}
