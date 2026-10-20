# registry_cli

给「远端 registry 里的镜像 → 本地镜像产物」这条通路做一件事：**自己当 registry 客户端**。
走 OCI Distribution Spec 的 Pull 流程（`token → manifest → blobs`），
再按 `docker save` 的结构打包成 tar，或者原样摆成 OCI Image Layout。

全程只碰 HTTP：不连 daemon、不 fork `docker` / `podman` / `nerdctl`。
原版 dive 没有这个能力——它所有镜像来源都绕不开本地 daemon。

## 快速开始

```moonbit nocheck
///|
async fn example() -> Unit {
  let reference = @registry_cli.parse_reference("library/nginx:1.27")
  // 只拉不落盘：拿到 config 与层（层是压缩的原始 blob）
  let image = @registry_cli.pull_image(reference)
  println("\{image.layers.length()} layers")
}
```

落盘用 `save_image`：

```moonbit nocheck
///|
async fn save() -> Unit {
  // docker-archive：一个 tar 文件，层已解压，能直接喂给 P2/P3/P4
  let _ = @registry_cli.save_image(
    @registry_cli.SaveRequest::new(
      reference="library/nginx:1.27",
      output="nginx.tar",
    ),
  )
  // OCI layout：一个目录，blob 原样落盘，无损搬运
  let result = @registry_cli.save_image(
    @registry_cli.SaveRequest::new(
      reference="library/nginx:1.27",
      output="./nginx-oci",
      format=@registry_cli.OciLayout,
    ),
  )
  println(result.path)
}
```

## 两步分开

- `pull_image` / `pull_with_client`：只管「把字节拿下来」，产物是 `RemoteImage`
- `package_image`：只管「把 `RemoteImage` 摆成某种格式」，产物是 `ArchiveBundle`

分开的好处是两者都能单独测：拉取用假 registry 起真 HTTP，
打包用手里造好的 `RemoteImage`，不必为了测打包去连网络。

## 两个产物格式

| | 结构 | 要点 |
|---|---|---|
| `DockerArchive` | `manifest.json` + `<config>.json` + `<diff-id>/layer.tar` | 层要**解压**；目录名是**解压后** tar 的 sha256 |
| `OciLayout` | `oci-layout` + `index.json` + `blobs/sha256/<digest>` | blob 原样落盘，不重算 sha256 |

zstd 层与 gzip 层一样被**解开后**写成 `layer.tar`：docker-archive 的目录名是
解压后 tar 的 sha256，所以压不压缩对产物没影响。解不开的层会带着层 digest
报错，不会被静默塞进归档。

## 边界

只读：没有 push、没有 Basic 认证、没有断点续传。
细节与取舍见 [`docs/p7-registry-cli.md`](../docs/p7-registry-cli.md)。
