///|
/// 逐路径版本表的构造：`[("路径", [各版本字节])]`。
fn versions_of(
  pairs : Array[(String, Array[Int32])],
) -> Map[String, Array[Int32]] {
  let map : Map[String, Array[Int32]] = Map([])
  for pair in pairs {
    map.set(pair.0, pair.1)
  }
  map
}

///|
async test "no rewrite means a perfect score" {
  // 三个路径各只写一次：Σmin == Σcumulative
  let report = efficiency_of_versions(
    versions_of([("/a", [10]), ("/b", [5]), ("/c", [1])]),
  )
  assert_eq(report.efficiency.min_bytes, 16)
  assert_eq(report.efficiency.cumulative_bytes, 16)
  assert_eq(report.efficiency.score(), 1.0)
  assert_eq(report.efficiency.wasted_ratio(), 0.0)
  assert_true(report.paths.is_empty())
}

///|
async test "equal size rewrite costs exactly half" {
  // dive 的口径按路径聚合所有版本：两次各 10 字节，
  // min=10、cumulative=20，重复写入的空间被折半
  let report = efficiency_of_versions(versions_of([("/f", [10, 10])]))
  assert_eq(report.efficiency.min_bytes, 10)
  assert_eq(report.efficiency.cumulative_bytes, 20)
  assert_eq(report.efficiency.score(), 0.5)
  assert_eq(report.paths.length(), 1)
  assert_eq(report.paths[0].versions, 2)
}

///|
async test "shrinking rewrite keeps the small version as min" {
  // 先 100 后 10：min=10、cumulative=110
  let report = efficiency_of_versions(versions_of([("/big", [100, 10])]))
  assert_eq(report.efficiency.min_bytes, 10)
  assert_eq(report.efficiency.cumulative_bytes, 110)
  assert_eq(report.paths[0].min_bytes, 10)
}

///|
async test "growing rewrite is penalised by the original small version" {
  // 先 10 后 100：min=10、cumulative=110，分数掉到 0.09
  let report = efficiency_of_versions(versions_of([("/f", [10, 100])]))
  assert_eq(report.efficiency.min_bytes, 10)
  assert_eq(report.efficiency.cumulative_bytes, 110)
  assert_true(report.efficiency.score() < 0.1)
}

///|
async test "deleting a file drags the score down" {
  // 被 whiteout 删掉：版本序列 [100, 0]，min=0、cumulative=100
  let report = efficiency_of_versions(
    versions_of([("/big", [100, 0]), ("/small", [1])]),
  )
  assert_eq(report.efficiency.min_bytes, 1)
  assert_eq(report.efficiency.cumulative_bytes, 101)
  assert_true(report.efficiency.score() < 0.01)
}

///|
async test "empty image scores 1.0 rather than dividing by zero" {
  let report = efficiency_of_versions(Map([]))
  assert_eq(report.efficiency.score(), 1.0)
  assert_eq(report.efficiency.cumulative_bytes, 0)
}

///|
async test "matches dive reference numbers from its own test fixture" {
  // 对照 dive `filetree/efficiency_test.go` 的 TestEfficiency：
  // nginx.conf 2000 -> 5000，public 3000，athing 10000，nginx 目录被 whiteout
  // 期望分数 0.75，低效路径是 /etc/nginx/nginx.conf（cumulative 7000）
  let report = efficiency_of_versions(
    versions_of([
      ("/etc/nginx/nginx.conf", [2000, 5000]),
      ("/etc/nginx/public", [3000]),
      ("/etc/athing", [10000]),
      ("/etc/nginx", [0]),
    ]),
  )
  assert_eq(report.efficiency.score(), 0.75)
  assert_eq(report.paths.length(), 1)
  assert_eq(report.paths[0].path, "/etc/nginx/nginx.conf")
  assert_eq(report.paths[0].cumulative_bytes, 7000)
}

///|
async test "analyze exposes the same efficiency as the raw version table" {
  let layers = [
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("app"),
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
    ]),
    layer_fixture([
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
    ]),
  ]
  let (_, analysis) = analyze_fixture(layers)
  let efficiency = analysis.efficiency()
  // 10 与 16 两个版本：min=10、cumulative=26
  assert_eq(efficiency.efficiency.min_bytes, 10)
  assert_eq(efficiency.efficiency.cumulative_bytes, 26)
  let expected = 10.0 / 26.0
  assert_true((efficiency.efficiency.score() - expected).abs() < 0.000001)
}

///|
async test "whiteout shows up in the version table as a zero" {
  let layers = [
    layer_fixture([@layer_tree.TarEntrySpec::File("big", "0123456789")]),
    layer_fixture([@layer_tree.TarEntrySpec::Whiteout("", "big")]),
  ]
  let (_, analysis) = analyze_fixture(layers)
  let efficiency = analysis.efficiency()
  assert_eq(efficiency.efficiency.min_bytes, 0)
  assert_eq(efficiency.efficiency.cumulative_bytes, 10)
  assert_eq(efficiency.efficiency.score(), 0.0)
}
