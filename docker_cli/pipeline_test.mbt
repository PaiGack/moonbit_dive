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

///|
/// 「本地没有就先拉」的调用顺序：`inspect` 说没有 → `pull` → `save`。
///
/// 顺序是这个能力的全部内容：光看最终归档分不清中间做没做 pull，
/// 拿 fake CLI 的调用日志才验得住。
async test "pull_if_missing inspects, pulls, then saves" {
  let dir = @fs.tmpdir(prefix="dive-pullflow-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  let archive = @docker_cli.build_docker_archive([
    ("beef", @layer_tree.build_tar([File("etc/os-release", "ID=moonbit")])),
  ])
  let archive_path = @docker_cli.write_temp_bytes("pullflow.tar", archive)
  let script = @docker_cli.fake_recording_cli(
    log,
    archive_path,
    "[]",
    inspect_code=1,
  )
  let (bin, _program) = @docker_cli.write_fake_cli_named("docker", script)
  let resolved = @docker_cli.resolve_backend(
    [@docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker)],
    { "PATH": bin },
  ) catch {
    err => fail("resolve should succeed: \{err}")
  }
  let saved = @docker_cli.save_maybe_pulling(
    resolved.backend,
    "example:latest",
    pull_if_missing=true,
  ) catch {
    err => fail("save_maybe_pulling should succeed: \{err}")
  }
  assert_eq(saved, archive)
  let calls = @fs.read_file(log).text()
  // 三次调用按序发生：先问本地有没有，没有就拉，拉完再取归档
  assert_true(calls.has_prefix("inspect example:latest"))
  assert_true(calls.contains("pull example:latest"))
  assert_true(calls.contains("save example:latest"))
  assert_true(
    calls.find("pull example:latest") < calls.find("save example:latest"),
  )

  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_temp_bytes(archive_path)
  @fs.rmdir(dir, recursive=true)
}

///|
/// 本地已经有了就**不拉**：`pull_if_missing` 不能变成「每次运行都上网」。
async test "pull_if_missing leaves a local image alone" {
  let dir = @fs.tmpdir(prefix="dive-pulllocal-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  let archive = @docker_cli.build_docker_archive([
    ("beef", @layer_tree.build_tar([File("etc/os-release", "ID=moonbit")])),
  ])
  let archive_path = @docker_cli.write_temp_bytes("pulllocal.tar", archive)
  let script = @docker_cli.fake_recording_cli(
    log, archive_path, "[{\"Id\":\"sha256:beef\"}]",
  )
  let (bin, _program) = @docker_cli.write_fake_cli_named("docker", script)
  let resolved = @docker_cli.resolve_backend(
    [@docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker)],
    { "PATH": bin },
  ) catch {
    err => fail("resolve should succeed: \{err}")
  }
  ignore(
    @docker_cli.save_maybe_pulling(
      resolved.backend,
      "example:latest",
      pull_if_missing=true,
    ) catch {
      err => fail("save_maybe_pulling should succeed: \{err}")
    },
  )
  let calls = @fs.read_file(log).text()
  assert_true(calls.contains("inspect example:latest"))
  assert_true(calls.contains("save example:latest"))
  assert_true(!calls.contains("pull example:latest"))

  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_temp_bytes(archive_path)
  @fs.rmdir(dir, recursive=true)
}

///|
/// 不给 `pull_if_missing`（缺省）时一次 `inspect` 都不做：默认行为与以前完全一致，
/// 不会因为多了个开关就平白多一次 daemon 往返。
async test "without pull_if_missing the backend is used as before" {
  let dir = @fs.tmpdir(prefix="dive-nopull-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  let archive = @docker_cli.build_docker_archive([
    ("beef", @layer_tree.build_tar([File("etc/os-release", "ID=moonbit")])),
  ])
  let archive_path = @docker_cli.write_temp_bytes("nopull.tar", archive)
  let script = @docker_cli.fake_recording_cli(
    log,
    archive_path,
    "[]",
    inspect_code=1,
  )
  let (bin, _program) = @docker_cli.write_fake_cli_named("docker", script)
  let resolved = @docker_cli.resolve_backend(
    [@docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker)],
    { "PATH": bin },
  ) catch {
    err => fail("resolve should succeed: \{err}")
  }
  let saved = @docker_cli.save_maybe_pulling(resolved.backend, "example:latest") catch {
    err => fail("save_maybe_pulling should succeed: \{err}")
  }
  assert_eq(saved, archive)
  let calls = @fs.read_file(log).text()
  assert_true(!calls.contains("inspect"))
  assert_true(!calls.contains("pull"))
  assert_true(calls.contains("save example:latest"))

  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_temp_bytes(archive_path)
  @fs.rmdir(dir, recursive=true)
}
