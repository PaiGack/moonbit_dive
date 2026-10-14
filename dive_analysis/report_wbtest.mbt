///|
/// 一份有代表性的镜像：基础层、覆盖层、删除层。
fn report_fixture() -> (@layer_tree.FileTree, Analysis) raise {
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
test "text report snapshots the whole picture" {
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
      #|  wasted: 15 bytes (48.4%)
      #|    overwritten: 10 bytes
      #|    deleted: 5 bytes
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
test "json report has the documented shape" {
  let (tree, analysis) = report_fixture()
  let json = report_to_json(build_report(analysis, tree))
  let fields = match json {
    Json::Object(fields) => fields
    _ => fail("report must be a JSON object")
  }
  assert_eq(fields.get("schemaVersion"), Some(Json(1)))
  assert_eq(fields.get("layers"), Some(Json(3)))
  let image = match fields.get("image") {
    Some(Json::Object(image)) => image
    _ => fail("image must be an object")
  }
  assert_eq(image.get("currentBytes"), Some(Json(16)))
  assert_eq(image.get("writtenBytes"), Some(Json(31)))
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
test "json report text is stable" {
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
      #|  "schemaVersion": 1,
      #|  "layers": 2,
      #|  "image": {
      #|    "currentBytes": 16,
      #|    "currentPaths": 2,
      #|    "writtenBytes": 26,
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
test "clean image reports no wasteful paths" {
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
test "largest directories rank by subtree size" {
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
