# 要不要做 docker cli？—— MoonBit 生态调研

结论：**不做 docker cli，也没有 moon docker cli 可复用**。
但「拿到镜像」这件事有两条现成的替代路径，本仓库只需要把输入接口对齐，
不必自己写 Engine 客户端，也不必自己写 registry 客户端。

调研时间基线：mooncakes.io 索引 3004 个模块（`GET /api/v0/modules` 全量核对）。

## 一、有没有 moon docker cli？

**没有。** 全量索引里没有任何模块是 Docker Engine API 客户端：

- 没有 `docker` / `dockerd` / `containerd` / `podman` / `buildah` / `moby` 的绑定
- 没有 `/var/run/docker.sock` 或 `tcp://DOCKER_HOST` 的封装
- `docker save` / `docker pull` / `docker build` 的 MoonBit CLI 不存在

所以「照抄 dive 的 `dockerClient.ImageSave()`」这条路在 MoonBit 侧没有落点。

### 顺带纠正一处误报

用 `moon search docker` 会搜到 `ryota0624/moonbit_test_containers`、`aspnmy/moonitest`，
看名字像是 docker 客户端，实际是**测试框架**：它们通过 FFI 起真实容器（Postgres/Redis/MySQL）
给集成测试用，不解析镜像、不读 Engine API，和 `dive` 的需求不交集。

## 二、生态里已有的相邻能力（可直接复用，别重造）

虽然 docker cli 没有，OCI 这条线上 MoonBit 生态意外地齐：

| 模块 | 能力 | 对本项目的意义 |
|---|---|---|
| `mizchi/oci_wasm` | OciClient：token 认证、list tags、get manifest、get blob（含 digest/size 校验）；`ffi` 包在 **native 和 js 两个 target 都有实现** | 想要「给个镜像名直接拉」时的 registry 客户端，不用自己写 |
| `mizchi/wacon` | OCI 容器运行时（WASM）：manifest/index 解析、registry pull 到本地 store | 参考实现，尤其 `oci` + `registry` 包的分层 |
| `oyjh0381/moonoci` | 确定性 OCI layout 构建与校验：`read_tar`/`write_tar`、sha256 流式、`is_whiteout_path`、`normalize_archive_path` | **和 P2 高度重叠**，见下节 |
| `Hhsqoo/artifactdock` | MoonBit 写的 OCI Distribution `/v2/` registry server | 端到端测试时本地起个 registry 推镜像，替代 docker registry |
| `bobzhang/tar` | 纯 MoonBit tar 读写（header + `Array[TarEntry]`） | 可用的 tar 底座，但见下节局限 |
| `bikallem/compress` | flate/gzip/zlib/zstd/brotli 全家桶 | 层解压（`tar+gzip`、`tar+zstd`） |
| `moonbit-community/flate` | 纯 MoonBit DEFLATE，无 IO 依赖可 suspend | 流式解压的备选 |
| `bobzhang/crescent`、`fangyinc/socket`、`moonbitlang/async` | HTTP 服务端 / socket / 异步 | 真要自己搓 Engine 客户端时的底座（**不建议**，见第四节） |

**没有的**：层叠文件树、whiteout diff、efficiency score —— 生态空白，正是本项目的贡献点。

## 三、一个必须知道的坑：`bobzhang/tar` 不够用

`bobzhang/tar@0.1.3` 的接口是 `data : String`（不是 `Bytes`），
且没有暴露 tar 头部的时间戳/uid/gid/mode。这意味着：

- 二进制层内容（可执行文件、字体）过 `String` 会丢信息
- 无法还原文件权限，而 whiteout 语义与权限差异恰恰是 P2 的核心

`oyjh0381/moonoci/archive` 的 `TarEntry::file(String, Bytes, mode)` 是对的形态，
但它是该模块的**内部类型**，只能整包依赖，不能单独取用。

**结论**：P2 不要指望直接吃 `bobzhang/tar`，要么自己写流式 tar reader（`Bytes` + 完整 header），
要么和 `oyjh0381/moonoci` 作者对齐出一个可复用的 tar 包。这是 P2 开工前必须先拍的事。

## 四、为什么不自己做 docker cli

即使 `fangyinc/socket` + `moonbitlang/async` 能把 `/var/run/docker.sock` 搓出来，也不建议：

1. **面积大且不长在核心上**：Engine API 有版本协商、`/images/{name}/get` 流式归档、
   `DOCKER_HOST`/`DOCKER_CONTEXT`/`ssh://`/`tls://` 等一整套，是 dive 里 197 行的 resolver
   背后的真实成本，但不产生本项目任何独有价值。
2. **砍掉它不产生能力缺口**：`docker save nginx:latest | dive -` 一行等价，
   而且更符合 Unix 习惯，还能顺带吃 podman/nerdctl/buildah 的 `save` 输出。
3. **和「不做 registry 拉取」的既有边界一致**：`docs/p1-oci-spec.md` 与
   `docs/p4-image-ci.md` 都已写过这条非目标，不需要为新需求推翻。

## 五、落到本仓库：输入接口对齐

不做 docker cli，但要把「用户习惯」的入口留住，只有这一件事要做：

**输入按顺序探测，自动识别三种格式**

| 输入 | 格式 | 处理 |
|---|---|---|
| `dive nginx.tar` | `docker save` 产物 | 读 `manifest.json` + `<hash>/layer.tar`，Docker 私有格式 |
| `dive ./oci-layout/` | OCI Image Layout | 读 `index.json` + `oci-layout` 标记 |
| `dive -` / `cat x \| dive` | stdin 流 | 同 docker-archive，流式读 |

其中 docker-archive 是**唯一必须打通**的格式 —— 它是「不做 docker cli」时
唯一还能保住用户习惯的接口，也是原版 dive 的 `docker/image_archive.go` 完整可复刻的部分。

`oci_spec/fixtures/docker_manifest.json` 已经放了 `application/vnd.docker.distribution.manifest.v2+json`
的样例，接口层可以马上照着写测试。

### P4 的 CLI 形态（建议）

```text
dive <docker-archive.tar | oci-layout-dir | -> [--rules rules.json] [--json] [--ci]
```

- 只读分析，不连 Engine、不连 registry
- `--json` 给机器消费、`--ci` 出注解 + exit code，两条非交互链路即可
- 交互式 TUI 不在范围内（原版 gocui 部分约 3500 行，是独立的大缺口，不混进这条）

## 六、如果要「一键拉取」：单独一层，不塞进 P1–P4

真想要 `dive nginx:latest` 的体验，正确做法是**把它做成可选的独立入口**，
复用生态而不是自研：

- `mizchi/oci_wasm` 当 registry 客户端拉 manifest + blobs
- 落到本地 store 后走 OCI layout 路径进 P2
- 作为独立包/独立命令，**不进入 P1–P4 的依赖链**，P1–P4 保持纯离线

这样既满足「查一下有没有 moon docker cli」——答案是**没有，但有 OCI 客户端**——
也不把 CI 门禁场景绑死在网络上。

## 参考

- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec)
- [wagoodman/dive](https://github.com/wagoodman/dive)（MIT）：
  `dive/image/docker/engine_resolver.go`、`dive/docker/image_archive.go`
