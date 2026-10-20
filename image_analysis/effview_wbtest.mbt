///|
/// 三层镜像：`/app/main.js` 被放大重写、`/lib/a` 被 whiteout 删掉、
/// `/app/util.js` 同大小重写一次——三种「多写」的形态都在里面。
async fn effview_fixture() -> EfficiencyReport {
  let layers = [
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("app"),
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
      @layer_tree.TarEntrySpec::File("app/util.js", "abcdefgh"),
      @layer_tree.TarEntrySpec::Dir("lib"),
      @layer_tree.TarEntrySpec::File("lib/a", "0123456789"),
    ]),
    layer_fixture([
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdefghij"),
      @layer_tree.TarEntrySpec::File("app/util.js", "abcdefgh"),
    ]),
    layer_fixture([@layer_tree.TarEntrySpec::Whiteout("lib", "a")]),
  ]
  let (_, analysis) = analyze_fixture(layers)
  analysis.efficiency()
}

///|
async test "efficiency view ranks by extra writes, not by wasted bytes" {
  let report = effview_fixture()
  let rows = efficiency_view_rows(report, EfficiencyViewOptions::new(top=10))
  assert_eq(rows.length(), 3)
  // 先写 10 再写 20：min=10、cumulative=30，多出来的是 20 字节
  assert_eq(rows[0].path, "/app/main.js")
  assert_eq(rows[0].versions, 2)
  assert_eq(rows[0].cumulative_bytes, 30)
  assert_eq(rows[0].min_bytes, 10)
  assert_eq(rows[0].size, 20)
  // 被 whiteout 删掉：min 取 0，整个 10 字节都算「多写的」
  assert_eq(rows[1].path, "/lib/a")
  assert_eq(rows[1].cumulative_bytes, 10)
  assert_eq(rows[1].min_bytes, 0)
  assert_eq(rows[1].size, 10)
  // 同大小重写：空间被占了两份，所以 size 等于单份大小
  assert_eq(rows[2].path, "/app/util.js")
  assert_eq(rows[2].size, 8)
}

///|
async test "rows add up to the efficiency denominator" {
  // 表里每行都能推出总分：Σcumulative 是分母，Σmin 是分子
  let report = effview_fixture()
  let rows = efficiency_view_rows(report, EfficiencyViewOptions::new(top=-1))
  let mut cumulative = 0
  let mut min = 0
  for row in rows {
    cumulative = cumulative + row.cumulative_bytes
    min = min + row.min_bytes
  }
  // 只写过一次的路径不在表里，它们只贡献分子的 min、不贡献分母，
  // 所以「Σcumulative == 分母」必须严格相等，而 Σmin 只覆盖重复写的路径
  assert_eq(report.efficiency.cumulative_bytes, cumulative)
  assert_eq(min, 18)
  assert_eq(report.efficiency.min_bytes, 18)
  let expected = report.efficiency.min_bytes.to_double() /
    report.efficiency.cumulative_bytes.to_double()
  assert_true((report.efficiency.score() - expected).abs() < 0.000001)
}

///|
async test "top truncates after the path filter, not before" {
  let report = effview_fixture()
  // 前 1 条是 /app/main.js；只看 /app 下再取前 1 条，仍该是它
  let scoped = efficiency_view_rows(
    report,
    EfficiencyViewOptions::new(path=Some("/app"), top=1),
  )
  assert_eq(scoped.length(), 1)
  assert_eq(scoped[0].path, "/app/main.js")
  // 只看 /lib 时只剩一条，top 再小也不该把它挤掉
  let lib = efficiency_view_rows(
    report,
    EfficiencyViewOptions::new(path=Some("/lib"), top=1),
  )
  assert_eq(lib.length(), 1)
  assert_eq(lib[0].path, "/lib/a")
}

///|
async test "path prefix tolerates a trailing slash and a missing leading one" {
  let report = effview_fixture()
  for prefix in ["/app/", "/app", "app"] {
    let rows = efficiency_view_rows(
      report,
      EfficiencyViewOptions::new(path=Some(prefix), top=-1),
    )
    assert_eq(rows.length(), 2)
    assert_eq(rows[0].path, "/app/main.js")
  }
}

///|
async test "top 0 means no truncation" {
  let report = effview_fixture()
  let all = efficiency_view_rows(report, EfficiencyViewOptions::new(top=-1))
  assert_eq(all.length(), 3)
  let none = efficiency_view_rows(report, EfficiencyViewOptions::new(top=0))
  // `--top 0` 在 CLI 里翻成 -1，这里直接传 0 表示「一条都不要」
  assert_eq(none.length(), 0)
}

///|
async test "text view snapshots the table" {
  let report = effview_fixture()
  inspect(
    render_efficiency_view(report, EfficiencyViewOptions::new(top=10)),
    content=(
      #|efficiency: 32.1% (18/56)
      #|paths by extra writes (cumulative - min), scope: /, showing 3:
      #|  20 bytes  cumulative 30  min 10  x2  /app/main.js
      #|  10 bytes  cumulative 10  min 0  x2  /lib/a
      #|  8 bytes  cumulative 16  min 8  x2  /app/util.js
      #|
    ),
  )
}

///|
async test "empty scope renders none instead of an empty table" {
  let report = effview_fixture()
  inspect(
    render_efficiency_view(
      report,
      EfficiencyViewOptions::new(path=Some("/nope"), top=10),
    ),
    content=(
      #|efficiency: 32.1% (18/56)
      #|paths by extra writes (cumulative - min), scope: /nope, showing 0:
      #|  (none)
      #|
    ),
  )
}

///|
async test "json view mirrors the text columns" {
  let report = effview_fixture()
  let json = efficiency_view_to_json(
    report,
    EfficiencyViewOptions::new(path=Some("/app"), top=1),
  )
  let fields = match json {
    Json::Object(fields) => fields
    _ => fail("efficiency view must be a JSON object")
  }
  assert_eq(
    fields.get("schemaVersion"),
    Some(Json(efficiency_view_schema_version)),
  )
  assert_eq(fields.get("path"), Some(Json("/app")))
  assert_eq(fields.get("top"), Some(Json(1)))
  assert_eq(fields.get("metric"), Some(Json("cumulativeMinusMin")))
  let efficiency = match fields.get("efficiency") {
    Some(Json::Object(efficiency)) => efficiency
    _ => fail("efficiency must be an object")
  }
  // JSON 里的分数与文本抬头是同一个数：文本按一位小数印刷
  assert_eq(efficiency.get("minBytes"), Some(Json(report.efficiency.min_bytes)))
  assert_eq(
    efficiency.get("cumulativeBytes"),
    Some(Json(report.efficiency.cumulative_bytes)),
  )
  let rows = match fields.get("paths") {
    Some(Json::Array(rows)) => rows
    _ => fail("paths must be an array")
  }
  assert_eq(rows.length(), 1)
  assert_eq(
    rows[0],
    Json::object({
      "path": Json("/app/main.js"),
      "versions": Json(2),
      "cumulativeBytes": Json(30),
      "minBytes": Json(10),
      "size": Json(20),
    }),
  )
}

///|
async test "a perfectly efficient image has an empty table" {
  let (_, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::File("a", "0123456789"),
      @layer_tree.TarEntrySpec::File("b", "1"),
    ]),
  ])
  let report = analysis.efficiency()
  let rows = efficiency_view_rows(report, EfficiencyViewOptions::new(top=-1))
  assert_true(rows.is_empty())
  assert_true(
    render_efficiency_view(report, EfficiencyViewOptions::new()).contains(
      "  (none)",
    ),
  )
}
