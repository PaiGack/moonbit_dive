///|
/// 读取 `oci_spec/fixtures/` 下的测试数据。
///
/// 测试从包目录运行，因此用相对本包根目录的路径。
fn fixture(name : String) -> String raise {
  @fs.read_file_to_string("oci_spec/fixtures/\{name}")
}
