///|
/// 测试夹具：手工造镜像的分析结果，供规则判定与输出测试共用。
///
/// 放在普通文件里（不是 `_test.mbt`）：同包的 test 文件要通过 `@image_ci` 前缀
/// 才能拿到它，这也顺带确认这些辅助函数没被误当成公开 API 导出。

///|
/// 造一份两层镜像的分析结果：`/app/main.js` 从 10 字节被覆盖成 16 字节。
/// 返回 (report, tree)。
pub fn covered_fixture() -> (@image_analysis.Report, @layer_tree.FileTree) raise {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
  ])
  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = [layer0, layer1]
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }
  (@image_analysis.build_report(analysis, tree), tree)
}

///|
/// 造一份「胖」镜像：`node_modules` 塞进大文件，且跨层重复写。
pub fn fat_fixture() -> (@image_analysis.Report, @layer_tree.FileTree) raise {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("node_modules"),
    @layer_tree.TarEntrySpec::File("node_modules/pkg/index.js", "0123456789"),
    @layer_tree.TarEntrySpec::File("app.js", "hello"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File(
      "node_modules/pkg/index.js", "0123456789abcdefghij",
    ),
  ])
  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = [layer0, layer1]
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    err => fail(err.to_string())
  }
  (@image_analysis.build_report(analysis, tree), tree)
}

///|
/// 合并版的覆盖写入夹具，给同包其他测试文件用。
pub fn covered_pair() -> (@image_analysis.Report, @layer_tree.FileTree) raise {
  covered_fixture()
}

///|
/// 端到端测试用的 docker save 产物：
/// `manifest.json` + `config.json` + 两层 `layer.tar`，两层里 `/app/main.js`
/// 与 `/node_modules/pkg/index.js` 各被覆盖一次（制造浪费）。
pub fn sample_docker_archive() -> Bytes {
  let layer0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789"),
    @layer_tree.TarEntrySpec::Dir("node_modules"),
    @layer_tree.TarEntrySpec::File("node_modules/pkg/index.js", "0123456789"),
  ])
  let layer1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main.js", "0123456789abcdef"),
    @layer_tree.TarEntrySpec::File(
      "node_modules/pkg/index.js", "0123456789abcdefghij",
    ),
  ])
  let config =
    #|{ "architecture": "amd64", "os": "linux", "rootfs": { "type": "layers", "diff_ids": ["sha256:aaaa", "sha256:bbbb"] } }
  let manifest =
    #|[ { "Config": "config.json", "RepoTags": ["demo/sample:latest"], "Layers": ["sl0/layer.tar", "sl1/layer.tar"] } ]
  let builder = @layer_tree.TarBuilder::new()
  builder.add_file("sl0/layer.tar", bytes_to_text(layer0))
  builder.add_file("sl1/layer.tar", bytes_to_text(layer1))
  builder.add_file("config.json", config)
  builder.add_file("manifest.json", manifest)
  builder.finish()
}

///|
/// 把 tar 字节塞进另一个 tar：内容是 ascii，按字节转字符再写。
fn bytes_to_text(data : Bytes) -> String {
  let builder = StringBuilder()
  for byte in data {
    builder.write_char(byte.to_int().unsafe_to_char())
  }
  builder.to_string()
}
