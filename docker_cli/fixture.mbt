///|
/// 测试用的 docker-archive 构造器：拼出 `docker save` 的最小结构。
///
/// 生产代码只读归档（镜像是外部产物），写能力只为测试服务，
/// 与 `layer_tree` 里 `TarBuilder` 的处理一致。
pub fn build_docker_archive(
  layers : Array[(String, Bytes)],
  repoTags~ : Array[String] = ["example:latest"],
  config~ : String = "abc123.json",
  /// config.json 的内容。默认是能过 `parse_docker_archive` 的最小结构；
  /// 要走 P4 的 `ImageSource::from_tar_bytes`（会校 `rootfs.diff_ids`）时传个完整的。
  config_json~ : String = "{\"architecture\":\"amd64\",\"os\":\"linux\"}",
) -> Bytes {
  let builder = @layer_tree.TarBuilder::new()
  let layer_paths = []
  for entry in layers {
    let (id, content) = entry
    // 老格式的层路径是 `<id>/layer.tar`
    let path = "\{id}/layer.tar"
    layer_paths.push(path)
    builder.add_raw_file(path, content)
  }
  let config_path = config
  builder.add_file(config_path, config_json)
  builder.add_file(
    "manifest.json",
    manifest_text(config_path, repoTags, layer_paths),
  )
  builder.finish()
}

///|
/// 生成 `manifest.json` 的文本。手写而不是走 JSON 编码器：
/// 测试 fixture 要能一眼看出字段名对不对。
fn manifest_text(
  config : String,
  repoTags : Array[String],
  layers : Array[String],
) -> String {
  let tag_items = []
  for tag in repoTags {
    tag_items.push("\"\{tag}\"")
  }
  let layer_items = []
  for layer in layers {
    layer_items.push("\"\{layer}\"")
  }
  "[{\"Config\":\"\{config}\",\"RepoTags\":[\{tag_items.join(",")}]," +
  "\"Layers\":[\{layer_items.join(",")}]}]"
}
