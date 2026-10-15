///|
/// 小体积 fixture 先验证生成器本身：结构要跟 `build_docker_archive` 一致，
/// 能被 `parse_docker_archive` / P2 吃下。
#cfg(not(platform="windows"))
async test "streaming fixture produces a parseable docker archive" {
  let dir = @fs.tmpdir(prefix="dive-bigfix-") catch {
    err => fail("tmpdir: \{err}")
  }
  let path = "\{dir}/big.tar"
  let written = @docker_cli.write_large_archive(path, 1024 * 64) catch {
    err => fail("write_large_archive failed: \{err}")
  }
  assert_eq(written, @fs.file_size(path).to_int())
  let archive = @fs.read_file(path).binary()
  let parsed = @docker_cli.parse_docker_archive(archive) catch {
    err => fail("generated archive should parse: \{err}")
  }
  let entry = @docker_cli.primary_entry(parsed).unwrap()
  assert_eq(entry.layers.length(), 1)
  assert_eq(entry.layers[0], "deadbeef/layer.tar")
  @fs.rmdir(dir, recursive=true)
}
