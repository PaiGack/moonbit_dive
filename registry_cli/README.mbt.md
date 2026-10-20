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

## 进度

拉一个几百 MB 的镜像要能看见「到哪了」，所以拉取过程会往外报 `PullEvent`：

```moonbit nocheck
///|
async fn with_progress() -> Unit {
  let reporter = @registry_cli.PullReporter::new()
  let _ = @registry_cli.save_image(
    @registry_cli.SaveRequest::new(
      reference="library/nginx:1.27",
      output="nginx.tar",
      on_progress=Some(reporter.handle()),
      // 回调是同步的，写终端也是同步的：每报一格就刷一次
      on_tick=Some(fn() { reporter.flush() }),
    ),
  )
}
```

`PullEvent` 只说事实（第几层、已下多少、总量多少），
百分比与 `\r` 重画是 `PullReporter` 的事——以后的 TUI 换掉这一层就够了。

`on_tick` 是「报完立刻画一下」的钩子：进度回调是同步的，
而终端写入在一些实现里是 async 的，中间没有可插入 await 的缝。
不接这个钩子进度依然正确，只是刷新会晚到下一层。

## 大层是怎么读的

`HttpReply` 只收响应头，正文靠 `read_body` / `read_body_with` 一段一段读
（64 KiB 一块）。之前的实现在 `read_all` 里把整段正文攒进内存，
攒到 700MB 就撞上 Int32 累加溢出：

```
Buffer capacity overflow
PanicError
```

而且那时候连一行进度都没有——两件事其实是一件事：
**层不是「一个 `Bytes`」，而是一条要先落到盘上的流**。

打包这一步同理：`docker save` 一个 700MB 的镜像，解压出来的层如果先攒成
一块再套 tar，峰值内存是「压缩 + 解压 + 打包」三份。所以 `write_image`
一路流式：解压出来的字节直接写进 tar 文件，中途只留一个 32 KiB 的窗口
（`decompress_layer_to` → `TarWriter` → 文件）。代价是每层要解压两遍——
第一遍只为了拿「未压缩 tar 的 sha256」当目录名，这一遍的字节直接扔掉
（`HashingWriter`）。两遍各是一次顺序扫描，换掉的是一份与镜像等大的内存。

## 两步分开

- `pull_image` / `pull_with_client`：只管「把字节拿下来」，产物是 `RemoteImage`
- `write_image`：只管「把 `RemoteImage` 摆成某种格式并落盘」，产物是落盘摘要

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
