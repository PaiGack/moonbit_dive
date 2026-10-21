///|
/// 一份有代表性的镜像：基础层、覆盖层、删除层。
async fn report_fixture() -> (@layer_tree.FileTree, Analysis) {
  analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("app"),
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
      @layer_tree.TarEntrySpec::File("app/README.md", "hello"),
    ]),
    layer_fixture([
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
    ]),
    layer_fixture([@layer_tree.TarEntrySpec::Whiteout("app", "README.md")]),
  ])
}

///|
async test "text report snapshots the whole picture" {
  let (tree, analysis) = report_fixture()
  inspect(
    render_text_report(build_report(analysis, tree)),
    content=(
      #|layers: 3
      #|  L0: +3 ~0 -0 paths, wrote 15 bytes, wasted 0 bytes
      #|  L1: +0 ~1 -0 paths, wrote 16 bytes, wasted 10 bytes
      #|  L2: +0 ~0 -1 paths, wrote 0 bytes, wasted 5 bytes
      #|image:
      #|  current: 16 bytes in 2 paths
      #|  written: 31 bytes
      #|  user written: 1 bytes (all layers but the base)
      #|  wasted: 21 bytes (67.7%)
      #|    by path (cumulative - min): 21 bytes
      #|    overwritten: 10 bytes
      #|    deleted: 5 bytes
      #|  user wasted: 2100% of 1 bytes
      #|efficiency: 32.3% (10/31)
      #|wasteful paths:
      #|  10 bytes  x2  /app/main.js
      #|  5 bytes  x1  /app/README.md
      #|largest directories:
      #|  16 bytes  1 files  /app
      #|
    ),
  )
}

///|
async test "json report has the documented shape" {
  let (tree, analysis) = report_fixture()
  let json = report_to_json(build_report(analysis, tree))
  let fields = match json {
    Json::Object(fields) => fields
    _ => fail("report must be a JSON object")
  }
  assert_eq(fields.get("schemaVersion"), Some(Json(2)))
  assert_eq(fields.get("layers"), Some(Json(3)))
  let image = match fields.get("image") {
    Some(Json::Object(image)) => image
    _ => fail("image must be an object")
  }
  assert_eq(image.get("currentBytes"), Some(Json(16)))
  assert_eq(image.get("writtenBytes"), Some(Json(31)))
  // dive 的两个同名出口：`wastedBytes` 取 `cumulative - min`（= `Σ paths[].size`），
  // 那个数不等于下面 `wasted` 拆分里的 10 + 5 —— 两者口径不同，别混用
  assert_eq(image.get("wastedBytes"), Some(Json(21)))
  assert_eq(image.get("userBytes"), Some(Json(1)))
  assert_eq(wasted_bytes(build_report(analysis, tree)), 21)
  assert_true(wasted_bytes(build_report(analysis, tree)) != 10 + 5)
  // `userWastedPercent` 的分母不含第 0 层：L0 写 15，L1 写 16 又被 L2 删掉 5，
  // 用户净写 1 字节 —— 用户只该为自己那几层负责
  assert_eq(image.get("userWastedPercent"), Some(Json(21.0)))
  assert_eq(
    image.get("wasted"),
    Some(Json::object({ "overwritten": Json(10), "deleted": Json(5) })),
  )
  let efficiency = match fields.get("efficiency") {
    Some(Json::Object(efficiency)) => efficiency
    _ => fail("efficiency must be an object")
  }
  assert_eq(efficiency.get("minBytes"), Some(Json(10)))
  assert_eq(efficiency.get("cumulativeBytes"), Some(Json(31)))
  let stats = match fields.get("layerStats") {
    Some(Json::Array(stats)) => stats
    _ => fail("layerStats must be an array")
  }
  assert_eq(stats.length(), 3)
}

///|
async test "json report text is stable" {
  let (tree, analysis) = analyze_fixture([
    layer_fixture([@layer_tree.TarEntrySpec::File("app/main.js", "0123456789")]),
    layer_fixture([
      @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
    ]),
  ])
  inspect(
    report_to_json_string(build_report(analysis, tree)),
    content=(
      #|{
      #|  "schemaVersion": 2,
      #|  "layers": 2,
      #|  "image": {
      #|    "currentBytes": 16,
      #|    "currentPaths": 2,
      #|    "writtenBytes": 26,
      #|    "userBytes": 6,
      #|    "wastedBytes": 16,
      #|    "userWastedPercent": 2.666667,
      #|    "wasted": {
      #|      "overwritten": 10,
      #|      "deleted": 0
      #|    }
      #|  },
      #|  "efficiency": {
      #|    "score": 0.384615,
      #|    "minBytes": 10,
      #|    "cumulativeBytes": 26
      #|  },
      #|  "layerStats": [
      #|    {
      #|      "layer": 0,
      #|      "addedPaths": 1,
      #|      "overwrittenPaths": 0,
      #|      "deletedPaths": 0,
      #|      "writtenBytes": 10,
      #|      "wastedBytes": 0,
      #|      "erasedBytes": 0
      #|    },
      #|    {
      #|      "layer": 1,
      #|      "addedPaths": 0,
      #|      "overwrittenPaths": 1,
      #|      "deletedPaths": 0,
      #|      "writtenBytes": 16,
      #|      "wastedBytes": 10,
      #|      "erasedBytes": 0
      #|    }
      #|  ],
      #|  "wastefulPaths": [
      #|    {
      #|      "path": "/app/main.js",
      #|      "currentBytes": 16,
      #|      "wastedBytes": 10,
      #|      "writes": 2,
      #|      "deleted": false,
      #|      "currentLayer": 1
      #|    }
      #|  ],
      #|  "largestDirectories": [
      #|    {
      #|      "path": "/app",
      #|      "cumulativeBytes": 16,
      #|      "files": 1
      #|    }
      #|  ]
      #|}
    ),
  )
}

///|
async test "clean image reports no wasteful paths" {
  let (tree, analysis) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("bin"),
      @layer_tree.TarEntrySpec::File("bin/sh", "0123456789"),
    ]),
  ])
  let report = build_report(analysis, tree)
  assert_eq(report.efficiency.score(), 1.0)
  assert_true(report.wasteful_paths.is_empty())
  assert_true(render_text_report(report).contains("  (none)"))
}

///|
async test "largest directories rank by subtree size" {
  let (tree, _) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("small"),
      @layer_tree.TarEntrySpec::File("small/a", "1"),
      @layer_tree.TarEntrySpec::Dir("big"),
      @layer_tree.TarEntrySpec::File("big/a", "0123456789"),
      @layer_tree.TarEntrySpec::File("big/b", "0123456789"),
    ]),
  ])
  let spots = hotspots(tree, limit=2)
  assert_eq(spots.length(), 2)
  assert_eq(spots[0].path, "/big")
  assert_eq(spots[0].cumulative_bytes, 20)
  assert_eq(spots[0].files, 2)
  assert_eq(spots[1].path, "/small")
  assert_eq(spots[1].cumulative_bytes, 1)
}

///|
/// 热点走父链上卷（issue #122）：每一级祖先都要把它下面所有文件的字节累加进来，
/// `depth` 之外的目录既不出现也不参与统计。
async test "hotspots roll up through the whole ancestor chain" {
  let (tree, _) = analyze_fixture([
    layer_fixture([
      @layer_tree.TarEntrySpec::Dir("a"),
      @layer_tree.TarEntrySpec::Dir("a/b"),
      @layer_tree.TarEntrySpec::Dir("a/b/c"),
      @layer_tree.TarEntrySpec::File("a/b/c/deep.bin", "0123456789"),
      @layer_tree.TarEntrySpec::File("a/b/mid.bin", "01234"),
      @layer_tree.TarEntrySpec::File("a/top.bin", "012"),
    ]),
  ])
  // 全额：`/a` 是 10+5+3，`/a/b` 是 10+5，`/a/b/c` 只有 10
  let all : Array[Hotspot] = hotspots(tree, depth=-1, limit=3)
  assert_eq(
    all.map(fn(spot) { (spot.path, spot.cumulative_bytes, spot.files) }),
    [("/a", 18, 3), ("/a/b", 15, 2), ("/a/b/c", 10, 1)],
  )
  // 只留深度 1：`/a` 仍然算全量子树，更深的目录既不出现也不该被算进来
  let shallow : Array[Hotspot] = hotspots(tree, depth=1, limit=-1)
  assert_eq(shallow.length(), 1)
  let only = Hotspot::{
    path: "/a",
    cumulative_bytes: 18,
    files: 3,
    wasted_bytes: 0,
  }
  assert_eq(shallow[0], only)
}

///|
/// 父链上卷的口径等价于「每个目录扫一遍全表」——只是快得多。
///
/// 这里把老写法（`path_is_under` 全表扫）原样留作对照，用一份几百个目录 /
/// 几千个文件的树对拍。功能上钉住「口径没变」，跑起来顺便证明新写法不用
/// `目录数 × 文件数` 次比较（issue #122）。
async test "hotspot rollup agrees with the old full scan" {
  let entries : Array[@layer_tree.TarEntrySpec] = []
  for d in 0..<20 {
    entries.push(@layer_tree.TarEntrySpec::Dir("d\{d}"))
    for f in 0..<10 {
      entries.push(
        @layer_tree.TarEntrySpec::File(
          "d\{d}/f\{f}.bin",
          repeat_of("x", d + f + 1),
        ),
      )
    }
  }
  let (tree, _) = analyze_fixture([layer_fixture(entries)])
  let files = file_sizes(tree)
  let expected = []
  for path in tree.paths() {
    let is_dir = match tree.get(path) {
      Some(node) => node.is_dir()
      None => false
    }
    if !is_dir {
      continue
    }
    let mut total = 0
    let mut count = 0
    for file_path, size in files {
      if @layer_tree.path_is_under(file_path, path) {
        total = total + size
        count = count + 1
      }
    }
    expected.push((path, total, count))
  }
  let actual = hotspots(tree, depth=-1, limit=-1).map(fn(spot) {
    (spot.path, spot.cumulative_bytes, spot.files)
  })
  assert_eq(actual.length(), expected.length())
  let by_path : Map[String, (Int32, Int32)] = Map([])
  for item in actual {
    by_path.set(item.0, (item.1, item.2))
  }
  for pair in expected {
    assert_eq(by_path.get(pair.0), Some((pair.1, pair.2)))
  }
}

///|
/// 同一段字符重复 `times` 遍。
fn repeat_of(text : String, times : Int32) -> String {
  let builder = StringBuilder()
  for _ in 0..<times {
    builder.write_string(text)
  }
  builder.to_string()
}
