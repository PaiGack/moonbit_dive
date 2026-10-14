///|
/// 端到端：`docker save` 出来的 tar → 拆层 → P2 的 `apply_layers_with_diffs`
/// → P3 的 `analyze_layers`，全程不碰真实 daemon。
///
/// 这是 issue #17 的核心验收：CLI 后端产出的归档必须能直接被既有的
/// P1–P4 链路吃下，输入契约不变。
test "docker archive feeds P2 layer stacking and P3 analysis" {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
    @layer_tree.TarEntrySpec::File("app/config.json", "{}"),
  ])
  let layer1 = @layer_tree.build_tar([
    // 后一层覆盖 main.js 并删掉 config.json
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
    @layer_tree.TarEntrySpec::Whiteout("app", "config.json"),
  ])
  let archive = build_docker_archive([("aaaa", layer0), ("bbbb", layer1)])
  let parsed = @docker_cli.parse_docker_archive(archive) catch {
    err => fail("archive should parse: \{err}")
  }
  let entry = @docker_cli.primary_entry(parsed).unwrap()
  let layers = @docker_cli.extract_layers(archive, entry) catch {
    err => fail("layers should extract: \{err}")
  }
  assert_eq(layers.length(), 2)

  // 喂给 P2：层是按序排列的未压缩 tar
  let streams = layers.map(layer => layer.bytes[:])
  let stacked = @layer_tree.apply_layers_with_diffs(streams) catch {
    err => fail("P2 should accept the layers: \{err}")
  }
  assert_eq(stacked.diffs.length(), 2)
  assert_eq(stacked.diffs[1].removed, ["/app/config.json"])
  assert_eq(stacked.diffs[1].modified, ["/app/main.js"])

  // 喂给 P3：被覆盖的 10 字节算浪费
  let tree = @layer_tree.FileTree::new()
  let analysis = @image_analysis.analyze_layers(tree, streams) catch {
    err => fail("P3 should accept the layers: \{err}")
  }
  assert_eq(analysis.final_file_bytes, 16)
  assert_eq(analysis.overwritten_wasted, 10)

  let report = @image_analysis.build_report(analysis, tree)
  assert_true(report.efficiency.score() > 0.0)
}

///|
/// CLI 后端跑完整条链路：fake docker save → 拆层 → P2。
async test "cli backend output feeds P2 end to end" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit"),
  ])
  let archive = build_docker_archive([("cafe", layer)])
  let archive_path = write_temp_bytes("e2e.tar", archive)
  let program = write_fake_cli(
    fake_inspect_and_save(
      archive_path, "[{\"Id\":\"sha256:cafe\",\"Os\":\"linux\",\"Architecture\":\"amd64\"}]",
    ),
  )
  let source = @docker_cli.DockerCliSource::new(program)
  let saved = source.save("example:latest") catch {
    err => fail("save should succeed: \{err}")
  }
  let parsed = @docker_cli.parse_docker_archive(saved) catch {
    err => fail("saved archive should parse: \{err}")
  }
  let entry = @docker_cli.primary_entry(parsed).unwrap()
  let layers = @docker_cli.extract_layers(saved, entry) catch {
    err => fail("layers should extract: \{err}")
  }
  let stacked = @layer_tree.apply_layers_with_diffs(layers.map(l => l.bytes[:])) catch {
    err => fail("P2 should accept fake-docker output: \{err}")
  }
  assert_true(stacked.tree.get("/etc/os-release") is Some(_))
  remove_fake_cli(program)
  remove_temp_bytes(archive_path)
}
