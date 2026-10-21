# P7 `registry_cli`：远端 registry → 本地镜像产物（不依赖 docker）

issue [#65](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/65)。
调研在 [registry-to-tar-survey.md](registry-to-tar-survey.md)，这里是**实现说明**。

一句话：**自己当 registry 客户端**，`token → manifest → blobs` 三段 HTTP 把镜像拉下来，
按 `docker save` 的结构打包成 tar（或原样摆成 OCI layout）。全程不碰 daemon、
不 fork docker/podman/nerdctl。

原版 dive（Go）没有这个能力——它所有镜像来源都绕不开本地 daemon，
详见调研文档第 1 节。

## 1. 用法

```bash
# 只保存，不分析（最接近「直接 save 镜像」）
dive --save -o nginx.tar library/nginx:1.27

# 保存成 OCI layout（无损搬运，可直接推回 registry）
dive --save --archive-format oci -o ./nginx-oci library/nginx:1.27

# 拉下来直接分析，一条命令出报告（不用先存盘再喂进去）
dive library/nginx:1.27

# 多架构镜像选平台；自建 registry 走 http
dive --save --platform linux/arm64 -o x.tar ghcr.io/owner/repo:tag
dive --save --insecure-registry -o x.tar localhost:5000/team/app:dev

# 私有仓库：token 走环境变量，别写在命令行里（会进 shell history）
DIVE_REGISTRY_TOKEN=... dive --save -o x.tar registry.example.com/team/app:1.0

# 根证书不在系统默认位置时（容器镜像里很常见），指定一份 PEM
DIVE_CA_BUNDLE=/path/to/ca-bundle.crt dive --save -o x.tar registry.example.com/team/app:1.0
```

位置参数不是本地路径就当镜像引用：先问 docker（本机有就 `save`，没有就 `pull` 一次），
一个 docker 后端都没有时才走本包直连 registry。`--no-pull` 把后两条路一起关掉
（本次运行绝不出网）。`--save` 只对镜像引用生效：给一份已存在的本地归档会按参数错退 2。

**TLS 根证书**：`https://` registry 要校验对端证书，机器上得有 CA 包
（Debian 系 `apt install ca-certificates`）。缺了它握手一定失败，
所以客户端会自己从常见位置挑一份 bundle
（`/etc/ssl/certs/ca-certificates.crt`、`/etc/pki/tls/certs/ca-bundle.crt` 等，
见 `registry_cli/tls_roots.mbt`），挑不到才退回 OpenSSL 的系统默认。
`DIVE_CA_BUNDLE` 优先且**只认它**——指错了直接报错，不悄悄换一份。
报错里会写明用的是哪份 bundle，别让「缺 CA 包」看起来像「网络坏了」。
`--insecure-registry` 走 `http://` 且不校验证书，这条路上不读任何 bundle。

镜像引用有两条数据源，顺序固定——先 docker，一个后端都没有时才换本包：

| 顺序 | 数据源 | 依赖 | 什么时候走 |
|---|---|---|---|
| ① | 本机 daemon 里的镜像（`inspect` → `save`，缺了先 `pull`） | docker daemon 或 docker/podman/nerdctl | 探测得到后端 |
| ② | 远端 registry（本包直拉） | 只要网络 | ①一条能走的路都没有，且没给 `--no-pull` |

顺序不能对调：`docker save` 要求镜像已在 daemon 里，把本包拉到的 tar 再喂进 daemon
纯属绕圈。两条路的产物都是 docker-archive tar，谁拿到就谁往下走。

## 2. 链路

```
ImageReference::parse          nginx:1.27 → registry-1.docker.io/library/nginx:1.27
        ↓
GET /v2/<repo>/manifests/<ref> 401 → 解析 WWW-Authenticate → 换 token → 重放
        ↓                      index 就按 platform 选子 manifest，按 digest 再取一次
GET /v2/<repo>/blobs/<digest>  每个 descriptor 一次；307 跟到 CDN（不带 Authorization）
        ↓                      size 先对、再算 sha256 对 digest
write_image                    解压即写盘：docker-archive（层解压）或 OCI layout（blob 原样）
        ↓
                               一个 tar 文件 / 一个 blobs+index.json 目录
```

模块对照：

| 文件 | 职责 |
|---|---|
| `reference.mbt` | 引用解析：registry / repository / tag-or-digest，Docker Hub 补 `library/` |
| `auth.mbt` | `WWW-Authenticate` 挑战解析、凭据类型 |
| `client.mbt` | 只做 `GET` 的 HTTP 客户端（token 挂在客户端上，调用方不用自己拼头） |
| `pull.mbt` | 拉取主流程：换票、选平台、取 blob、校验 |
| `package.mbt` | 两种产物的打包与落盘（全程流式，不整包进内存） |
| `writer.mbt` | 三个落点：数着字节写文件、只算 sha256、攒成一块 |
| `save.mbt` | `save_image`：拉取 + 打包 + 落盘，CLI 只需要这一个入口 |

## 3. 几个必须说清楚的决定

**blob 保持压缩。** 拉下来存的是 registry 给的压缩字节。打包成 OCI layout 时原样落盘；
只有 docker-archive 才解压——「搬运镜像」不该付解压的 CPU 与内存。

**docker-archive 的目录名是 diff id，不是 blob digest。** `<id>/layer.tar` 里的 `<id>`
是**解压后** tar 的 sha256，也就是 config 里 `rootfs.diff_ids[i]`。写错的产物 docker 拒绝加载，
所以打包时顺手校验一遍 config，对不上直接报 `DigestMismatch`。

**zstd 层与 gzip 层走同一条路。** docker-archive 不在意 blob 压不压缩：层先解开，
再按未压缩 tar 算 sha256 当目录名。压缩方式由 media type 推（`compression_of`），
认不出来才当未压缩。解不开（真的坏了 / 参数不对）会带着层 digest 报错，
不会把压缩字节当 tar 塞进归档。

**重定向不带 Authorization。** blob 的 307 目标是 CDN 上的签名 URL，
把 registry token 一起送过去既没用也不合适。

**平台只在 index 里认。** 直接返回 manifest 时，服务端没声明平台，
我们的 `RemoteImage.platform` 就是空——请求参数只是「想要什么」，不是「拿到了什么」。

**本包直拉的产物走临时文件再读回来。** 三种输入格式（docker-archive / OCI layout /
单层 tar）的识别逻辑只有 `ImageSource::load` 一份，不为「内存里的镜像」再写一套。
分析完立刻删；用户给了 `-o` 就留着。

## 4. 补的基础件

- `layer_tree::TarWriter` / `TarWriteEntry` / `tar_file_entry` / `tar_directory_entry`
  —— 本仓原先只有 `TarReader`。用 `Buffer` + 512 对齐流式写，内存占用与镜像体积无关。
  **注意**：`TarWriter` 目前写进内存缓冲区，`finish()` 才给出字节，所以整包仍在内存里；
  真正需要「边拉边落盘」时再加 `write_to(File)` 的出口。
- `oci_spec::Digest::from_bytes` / `verify_digest` —— 按 digest 字符串校验字节，
  算法从 digest 里取，不必调用方先约定。

## 5. 没做的（明确划界）

- **没有 push。** 本包只读。要推回 registry 是另一件事（见调研文档路线 C）。
- **没有 Basic 认证。** 私有 registry 常见 Basic，但那要处理账号密码的落地方式，
  现在只接受 bearer token。遇到 `WWW-Authenticate: Basic` 会明确报
  `the registry asks for Basic auth, which needs a password; pass a token instead`。
- **没有断点续传 / 重试。** 单次拉取，失败就报错。大层断在中途要重拉。
- **不校验 manifest 自身的 digest**（响应头给的 `Docker-Content-Digest` 会记下来，
  但拿它跟 body 比一遍还没做）。blob 的 digest 是校验的。

## 6. 验证

单元与端到端测试在 `registry_cli/`：

- `reference_test.mbt` / `auth_test.mbt` / `client_test.mbt`：纯逻辑（解析、挑战、重定向）
- `registry_test.mbt`：**真起一个 HTTP 服务**当假 registry，跑通 manifest、index 选平台、
  平台不存在时报可选项、401 → 换票 → 重放
- `package_test.mbt`：两种产物的结构，包括「层目录名等于 config 的 diff id」、
  「OCI layout 里 blob 内容与文件名对得上」、「zstd 层被解开成未压缩 `layer.tar`」
- 真后端对拍（`scripts/docker-cli-probe.sh` 第 6 节）：一份 zstd 层镜像走完
  「docker save → 解压 → 建树 → 报告」，报告里的字节数对得上才算过

手工验过的真实链路（不依赖本地 docker）：

```bash
dive --save -o hello.tar library/hello-world:latest   # 1 层
dive library/nginx:1.27                               # 7 层 / 190MB
dive --save --archive-format oci -o layout library/hello-world:latest
```
