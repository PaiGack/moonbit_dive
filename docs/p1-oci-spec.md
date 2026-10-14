# P1 `oci_spec` — OCI image-spec 类型层

## 目标

把 OCI image-spec 的 JSON schema 翻译成 MoonBit 类型，提供 digest 解析校验与 media type 常量。
这是整个项目的基石：后面所有层都靠它描述"一个镜像由什么组成"。

## 范围

### 类型定义（对应 image-spec/schema）

- `Descriptor`：mediaType / digest / size / urls / annotations / platform / data
- `Platform`：architecture / os / os.version / os.features / variant
- `Index`（manifest list）：schemaVersion / mediaType / manifests / annotations
- `Manifest`：schemaVersion / mediaType / config / layers / subject / annotations
- `ImageConfig`：created / author / architecture / os / config / rootfs / history
- `RootFS`：type ("layers") / diff_ids
- `OCIBlob`（config blob 顶层）：created / author / architecture / os / config / rootfs / history
- `History`：created / created_by / author / comment / empty_layer

### digest

- `algorithm:hex` 解析（如 `sha256:abc...`），校验 hex 长度与字符集
- 与 sha256 计算结果的比对辅助函数
- 大小写规范化（OCI digest 必须小写 hex）

### media type 常量

`application/vnd.oci.image.manifest.v1+json`、`...index.v1+json`、`...image.config.v1+json`、
`...descriptor.v1+json`、docker 兼容的 `application/vnd.docker.*` 系列常量。

### 序列化

- 用 `@moonbitlang/json`（或 `encoding/json`）做读写，字段名遵循 OCI 的 camelCase
- 未知字段容忍（向后兼容 schema 演进），但核心字段缺失时报类型错误

## 非目标

- 不做网络：不实现 registry 客户端（那是另一个方向，`mizchi/oci_wasm` 已覆盖）
- 不解析 layer 内容（P2 的职责）

## 验收

- [ ] 所有 schema 类型有 MoonBit 定义，`moon info` 接口稳定
- [ ] fixture 驱动的测试：用 OCI 官方 test-cases 与真实镜像的 manifest/config JSON 做解析快照测试
- [ ] digest 非法输入（空、无冒号、未知算法、非 hex、大小写混用）有明确报错
- [ ] README 给出「读一个 manifest.json → 拿到 layers 列表」的最小示例
- [ ] `moon check` / `moon test` 全绿，无 warning

## 参考

- <https://github.com/opencontainers/image-spec>（Apache-2.0）
- dive 的 `dive/image/`：它只消费 manifest+config，没有自己的类型层，本包把它缺的补上
