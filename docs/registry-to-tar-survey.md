# 远端 registry → 本地 tar：不依赖本地 docker 的导出方案

**结论：可行，且是本项目的自然缺口。** 核心是**自己当 registry 客户端**走 OCI
Distribution Spec 的 Pull 流程，把 blob 按 `docker save` 的格式重新打包成 tar。
全程只碰 HTTP，不碰 daemon、不碰 docker/podman/nerdctl 可执行文件。

背景见 [issue #65](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/65)。
与 P5 的区别：P5 是「本机 daemon 里已有的镜像 → tar」，
本文是「远端 registry 里的镜像 → tar」，数据源完全不同。

## 1. 需求边界

| | 输入 | 中间依赖 | 输出 |
|---|---|---|---|
| P5 `docker_cli`（已做） | 本地镜像名 | docker daemon 或 CLI | docker-archive tar |
| **本文（新）** | 远端镜像引用 `reg/repo:tag` | **只要 HTTP + 网络** | docker-archive tar（或 OCI layout） |

用户原话：「将远端的镜像服务里面的镜像保存为本地的 tar 镜像文件，不依赖本地的 docker 服务。」
所以约束有三条：**远端拉取**、**产出 tar 文件**、**零本地 docker 依赖**。

原版 dive 没有这个能力（它只有 `docker.ImageSave`，见上文调研），
但这恰好是「CI 里没有 daemon」「想在纯离线环境先备好镜像」的真实场景。

## 2. 技术路线：直接实现 OCI Distribution Pull

不需要 daemon，也不需要 `docker pull`。registry 就是一堆 HTTP 端点，
拉一个镜像 = 下面这条链路。

### 2.1 认证（Bearer challenge）

对 `GET /v2/` 或直接请求 manifest，未带凭证会拿到：

```
401 Unauthorized
WWW-Authenticate: Bearer realm="https://auth.docker.io/token",
                  service="registry.docker.io",
                  scope="repository:library/nginx:pull"
```

处理：解析 `realm` / `service` / `scope` → 请求
`{realm}?service={service}&scope={scope}` → 拿 JSON 里的 `token` / `access_token`
→ 后续请求带 `Authorization: Bearer <token>`。

Docker Hub 匿名即可取 token（`scope=...:pull`）。已实测：
`curl "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/nginx:pull"`
返回可用 token，之后带 `Authorization` 就能读 manifest。

要点：
- `scope` 为多仓库合并时要拆成多个 `scope=` 参数（本场景单仓库，够用）
- token 有过期时间（`expires_in`），长任务要能刷新
- Basic 认证（`WWW-Authenticate: Basic`）也要支持——私有 registry 常见
- 401 只发生一次，拿到 token 后应在会话里缓存

### 2.2 取 manifest（含 index / 平台选择）

```
GET /v2/<name>/manifests/<tag-or-digest>
Accept: application/vnd.oci.image.index.v1+json,
        application/vnd.docker.distribution.manifest.list.v2+json,
        application/vnd.oci.image.manifest.v1+json,
        application/vnd.docker.distribution.manifest.v2+json
```

两种返回：

1. **index / manifest list** → 按 `platform.os` / `architecture` / `variant`
   选一个子 manifest，再 `GET` 该 digest
2. **manifest** → 直接拿到 `config` + `layers[]` 描述符

响应头 `Docker-Content-Digest` 是权威 digest，应校验。
`Content-Type` 决定是 index 还是 manifest——不能只看 body 字段。

已实测：`library/nginx:latest` 返回 index，选 `linux/amd64` 子项即完整 manifest。

### 2.3 取 config 与 layers

```
GET /v2/<name>/blobs/<digest>        # 每个 descriptor 一次
```

- 层是**压缩 blob**（`+gzip` / `+zstd`），拉下来就是原始压缩字节
- 大层要**流式落盘 + 边下边算 sha256**，不能整层进内存
  （P5 已有「不驻留内存」的工程约束，同样的纪律）
- 下完校验 `sha256(body) == digest`，不符即 `DigestMismatch`
- registry 会 307 重定向到 CDN，HTTP 客户端要跟随 `Location`

### 2.4 打包成 tar

这里有两个目标格式，**建议都支持，用 flag 选**：

**A. docker-archive（对齐现有输入契约，首选）**

`docker save` 的产物结构：

```
manifest.json            # [{Config, RepoTags, Layers[]}]
<config-hex>.json        # 镜像 config
<layer-id>/layer.tar     # 未压缩层，按层序
```

要点：
- 层必须**解压**（gzip/zstd → tar），因为 docker-archive 里的 `layer.tar` 是未压缩的
- `<layer-id>` 是「层的链式 ID」：`sha256(config.diff_ids[i])`，
  即对该层解压后的 tar 做 sha256（不是压缩 blob 的 digest）
- `RepoTags` 填用户给的 `reg/repo:tag`
- 想省时间可以不重新压缩，直接把解压后的层写进 `layer.tar`

**B. OCI Image Layout（更简单，无损）**

```
oci-layout               # {"imageLayoutVersion":"1.0.0"}
index.json               # 指向子 manifest
blobs/sha256/<digest>    # config + 原始压缩层，digest 即文件名
```

要点：**blob 原样落盘即可**，不需要解压、不需要重算 sha256，
只要把注册表里下到的字节按 digest 命名，再拼出 `index.json` + `manifest`。
这是最省事、最忠实的格式，也是「镜像搬运」场景的推荐产物。

> 本项目现有链路（P2/P3）吃的是 docker-archive。若只要一份能喂给分析的产物，
> 选 A；若目的是「备份/搬运镜像」，选 B（无损、可再推回 registry）。

## 3. 落到本项目的方案

### 3.1 单独成包 `registry_cli`

理由和当初 P5 独立成包一致：

- P1–P4 的契约是**纯离线、不绑网络**，不能因为新能力被推翻
- P5 的 `ImageSource` 抽象刻意只有「本地读」，塞不进「远端拉」
- 新包只产 docker-archive / OCI layout，**复用既有输入契约**，不新开分析链路

### 3.2 建议的接口草案

```text
// 参考形态，非最终 API
pub(all) struct RegistrySource {
  // 解析出的 registry / repository / reference
}

pub async fn RegistrySource::pull(ref : String, opts : PullOptions) -> Unit raise RegistryError

pub(all) struct PullOptions {
  platform : Platform?        // 缺省当前架构；index 必需
  format   : ArchiveFormat    // DockerArchive | OciLayout
  output   : String           // 目标 tar 路径 / 目录
  insecure : Bool             // 允许 http:// 与自签证书
}
```

错误分类（对齐 P5 的做法，人话 + 可判定）：

- `Auth`：401/403、token 换取失败
- `NotFound`：manifest/blob 404（仓库名或 tag 写错）
- `DigestMismatch`：blob 校验失败（传输损坏）
- `Unsupported`：遇到没实现的 manifest 类型 / 平台
- `Network`：连接、超时、重定向异常
- `Io`：落盘失败

### 3.3 依赖与复用

| 能力 | 来源 | 说明 |
|---|---|---|
| manifest / index / config 解析 | 本仓 `oci_spec` | 已覆盖 OCI + Docker 两套 media type，直接吃 |
| digest 校验 | 本仓 `oci_spec::Digest` | `verify_sha256` 已有 |
| 层解压（gzip/zstd） | 本仓 `layer_tree` 的 inflate / 生态 `bikallem/compress` | 打包 A 才需要 |
| HTTP 客户端 | `moonbitlang/async/http`（HTTPS 可用） | registry 走 `https://`，不是 unix socket |
| tar 写出 | **需要新写** | 本仓只有 TarReader，没有 TarWriter；见下 |

**缺口：tar writer。** `docker_cli/archive.mbt` 只解析 tar，打包需要写 tar。
`bobzhang/tar` 的 `String` 接口对二进制层不安全（见 docker-cli-survey 第三节），
建议在 `layer_tree` 里补一个流式 `TarWriter`（`Bytes` + 完整 header），
这在 P2 阶段就该有，正好一起补。

**缺口：zstd。** 现在主流层是 `+gzip`，但 `+zstd` 在增长。
打包格式 A 遇到 zstd 层要么引入 zstd 依赖，要么直接拒（明确报 `Unsupported`）。
格式 B 不受影响（原样落盘）。

### 3.4 生态可复用度

- **`mizchi/oci_wasm`**：有 pull 向的 `OciClient`（token / get_manifest / get_blob），
  **但没有我们要的出口**：
  - 无 tar 打包、无 docker-archive
  - blob 走 `String`，二进制层会丢信息
  - 有 `max_blob_size = 256MB` 上限，大层直接拒
  - `https://` 硬编码，私有/自签 registry 用不了
  - 偏 js target
  结论：**可当参考实现读，不作为依赖**，尤其它的 auth 流程值得对照。
- **`Hhsqoo/artifactdock`**：MoonBit 写的 registry server，
  可用来在测试里起一个**本地 registry**，端到端验证拉取与打包，无需连公网。
- **`mizchi/wacon`**：pull → 本地 store 的参考分层。

## 4. 与 P5 的关系

两者不冲突，是数据源的两端：

```
远端 registry ──[本文: registry_cli]──┐
                                      ├──> docker-archive tar ──> P2/P3/P4 分析
本机 daemon   ──[P5: docker_cli]────┘
```

可选：`cmd/main` 复用 P5 的 `--from-image` 风格，加一个 `--from-registry`
显式开关（不做魔数嗅探，和 P5 同样的理由）。

## 5. 验收建议（若立项）

- [ ] 匿名拉 Docker Hub 公共镜像（`library/<x>`）端到端成功，产出 tar
- [ ] 带 token 拉私有 registry（可用本地 `artifactdock` / `registry:2` 起）
- [ ] index → 按 platform 正确选子 manifest
- [ ] 每个 blob 落盘后 sha256 与 digest 一致；篡改用例报 `DigestMismatch`
- [ ] 大层走流式，内存不随层体积增长（对齐 P5 的 `save_to_file_memory_test.mbt`）
- [ ] 产物能被既有 `ImageSource::from_tar_bytes` 吃下，一路跑到体积报告
- [ ] 401 / 404 / 网络超时各有明确错误与 exit code，不 panic、不吞响应体

## 6. 一句话

**别动 daemon，自己当 registry 客户端。**
Pull 流程就是 `token → manifest(index→平台) → blobs` 三段 HTTP，
产物落成 docker-archive（对齐现有分析链路）或 OCI layout（无损搬运）。
单独成包，别碰 P1–P4 的离线契约；唯一要先补的基础件是一个 `Bytes` 版 tar writer。

## 参考

- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)（Apache-2.0，本文第 2 节流程依据）
- [OCI Image Layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md)
- [docker save 归档格式](https://docs.docker.com/reference/cli/docker/image/save/)
- `mizchi/oci_wasm`（Apache-2.0）：pull 向参考实现
- 本仓 [p5-docker-cli.md](p5-docker-cli.md)、[docker-cli-survey.md](docker-cli-survey.md)
