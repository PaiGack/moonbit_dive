///|
/// 这份层是**真 `zstd` 压出来的**：`tar` 里只有一个 `etc/motd`（内容是
/// `dive zstd layer\n`，10 字节），`zstd -19` 压完 112 字节。
///
/// 为什么放文件而不是内联字节：zstd 的帧要过 FSE 表 + 4-stream Huffman，
/// 手写编码器造不出来（`zstd_compress` 只发 raw/RLE 块），而这类帧正是
/// 真实镜像层里最常见的那种。夹具固定，所以测试结果是确定的。
///
/// 重新生成：`tar czf` 之前先 `tar` 出未压缩层，再 `zstd -19` 压它。
fn zstd_layer_fixture_path() -> String {
  "layer_tree/fixtures/etc-motd-layer.tar.zst"
}

///|
/// 读夹具的原始字节：解压路径要的是压缩后的 blob，不是解码后的 tar。
fn zstd_layer_fixture() -> Bytes raise {
  @fs.read_file_to_bytes(zstd_layer_fixture_path())
}

///|
async test "zstd: a real zstd -19 layer decompresses to a parsable tar" {
  let layer = zstd_layer_fixture()
  // 帧头魔数：这条断言保证夹具没在 checkin 时被当成文本改坏（比如换行符）
  assert_eq(layer[:4], b"\x28\xb5\x2f\xfd")
  let raw = zstd_decompress(layer[:])
  // tar 一定是 512 的整数倍，且至少有一个 header + 一个数据块 + 结束块
  assert_eq(raw.length() % 512, 0)
  assert_true(raw.length() >= 1536)
  let entries = parse_tar_entries(raw)
  let paths = entries.map(entry => entry.path)
  assert_eq(paths, ["etc/motd", "etc/"])
}

///|
async test "zstd: the decompressed layer applies to a file tree" {
  let tree = FileTree::new()
  apply_layer_with_media_type(
    tree,
    zstd_layer_fixture()[:],
    "application/vnd.oci.image.layer.v1.tar+zstd",
    0,
  )
  assert_eq(tree.size(), 2)
  match tree.get("/etc/motd") {
    Some(node) => assert_eq(node.info.size, 16)
    None => fail("/etc/motd is missing from the applied tree")
  }
}
