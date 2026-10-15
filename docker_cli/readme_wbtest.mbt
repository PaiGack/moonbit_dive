///|
/// README 里「本地没有就先拉」的示例原样跑一遍，防止文档漂移。
///
/// README 用的是 `@async_fs.*`（包内测试里就是本包已导入的
/// `moonbitlang/async/fs`），这里照抄逻辑、只把限定名换成包内可用的写法。
async test "README pull example runs as written" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit"),
  ])
  let archive = build_docker_archive([("beef", layer)])
  let archive_path = write_temp_bytes("readme-pull.tar", archive)
  let dir = @fs.tmpdir(prefix="dive-readme-pull-") catch {
    err => fail("tmpdir: \{err}")
  }
  let log = "\{dir}/calls.log"
  // inspect 失败 = daemon 说本地没有；日志记下每次调用，好验证顺序
  let script = fake_recording_cli(log, archive_path, "[]", inspect_code=1)
  let (bin, _program) = write_fake_cli_named("docker", script)
  let resolved = resolve_backend([BackendCandidate::Cli(CliTool::Docker)], {
    "PATH": bin,
  }) catch {
    err => fail("resolve failed: \{err}")
  }
  let saved = save_maybe_pulling(
    resolved.backend,
    "nginx:latest",
    pull_if_missing=true,
  ) catch {
    err => fail("save_maybe_pulling failed: \{err}")
  }
  assert_eq(saved, archive)
  let calls = @fs.read_file(log).text()
  assert_true(calls.contains("pull nginx:latest"))
  assert_true(calls.find("pull nginx:latest") < calls.find("save nginx:latest"))

  remove_fake_cli_dir(bin)
  remove_fake_cli_dir(dir)
  remove_temp_bytes(archive_path)
}
