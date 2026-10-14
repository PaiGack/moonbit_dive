# `oci_spec` — OCI image-spec 类型层

把 [OCI image-spec](https://github.com/opencontainers/image-spec) 的 JSON schema
翻成 MoonBit 类型，外加 digest 解析校验与 media type 常量。
P2/P3 的 layer 叠加、白障 diff 与体积报告都从这里描述「一个镜像由什么组成」。

## 最小示例：读一个 manifest.json → 拿到 layers 列表

```mbt check
///|
test {
  let text =
    #|{
    #|  "schemaVersion": 2,
    #|  "mediaType": "application/vnd.oci.image.manifest.v1+json",
    #|  "config": {
    #|    "mediaType": "application/vnd.oci.image.config.v1+json",
    #|    "digest": "sha256:b5b2b2c507a0944348e0303114d8d93aaaa081732b86451d9bce1f432a537bc7",
    #|    "size": 7023
    #|  },
    #|  "layers": [
    #|    {
    #|      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
    #|      "digest": "sha256:ec4b8955958665577945c89419d1af06b5f7636b4ac3da7f12184802cdcf0b1",
    #|      "size": 32654
    #|    }
    #|  ]
    #|}
  let document = @oci_spec.parse_document(text).unwrap()
  let manifest = match document {
    Manifest(manifest) => manifest
    _ => fail("expected a manifest")
  }
  for layer in manifest.layers {
    println("\{layer.media_type} \{layer.digest} \{layer.size} bytes")
  }
  println("total \{manifest.total_layer_size()} bytes")
}
```

`parse_document` 会自动识别 manifest / index / config（先看 `mediaType`，缺失时按字段结构猜）。

## 换一个入口

- `parse_document(text)` → `Manifest` / `IndexDoc` / `ImageConfig`
- `parse_image_config_lenient(text)` → 只想要 config 且有工具漏了 `schemaVersion` 时
- `@json.from_json` → 类型已知时直接解码，例如 `let m : @oci_spec.Manifest = @json.from_json(json)`

## digest

```mbt check
///|
test {
  // 解析并校验：algorithm:hex，hex 必须小写、长度与算法匹配
  let digest = @oci_spec.Digest::parse(
    "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
  ).unwrap()
  inspect(
    digest.to_string(),
    content="sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
  )

  // 与计算出的字节摘要比对（sha256 前缀可省）
  assert_true(@oci_spec.Digest::verify_sha256(b"hello", digest.to_string()))

  // 非法输入有明确报错
  inspect(
    @oci_spec.Digest::parse("").unwrap_err().to_string(),
    content="digest is empty",
  )
}
```

非法输入分类：`EmptyDigest` / `MissingSeparator` / `MissingAlgorithm` / `EmptyEncoded` /
`UnsupportedAlgorithm` / `InvalidLength` / `InvalidHexChar` / `NotLowercase`。

## 设计取舍

- **未知字段容忍**：手写解析取字段表，schema 演进加字段不会炸；核心字段缺失才报错。
- **`config` 字段保留原始 JSON**：docker 还在往 `config` 里加键，全量建类型跟不上也没收益。
- **`Platform` 手写解析**：`os.version` / `os.features` 带点号，derive 生成不了。
- **digest 拒绝大写**：OCI 规范要求小写 hex；需要宽松处理外部输入时用 `normalize_digest`。

## 非目标

- 不做网络：registry 客户端不在这里
- 不解析 layer 内容：那是 P2 的活
