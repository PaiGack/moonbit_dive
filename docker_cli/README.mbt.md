# docker_cli

给「镜像名 → 本地归档」这条通路做两种后端：包装 `docker` / `podman` / `nerdctl`
可执行文件的 **CLI 后端**，和直连 `/var/run/docker.sock` 的 **Engine 后端**。
产物统一收敛到 docker-archive tar，直接喂给 P2 的层叠、P3 的体积分析。

这是 [dive](https://github.com/wagoodman/dive)（Go，MIT）`image/docker/engine_resolver.go`
的后端探测与降级思路在 MoonBit 上的实现；不引入 Go，也不依赖 docker binary 才能跑。

## 快速开始

```moonbit check
///|
async test "README example" {
  // 造一个假的 docker：inspect 吐 JSON，save 吐归档
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit"),
  ])
  let archive = @docker_cli.build_docker_archive([("beef", layer)])
  let archive_path = @docker_cli.write_temp_bytes("readme.tar", archive)
  let program = @docker_cli.write_fake_cli(
    @docker_cli.fake_inspect_and_save(
      archive_path, "[{\"Id\":\"sha256:beef\",\"Os\":\"linux\",\"Architecture\":\"amd64\"}]",
    ),
  )

  let source = @docker_cli.DockerCliSource::new(program)
  let info = source.inspect("example:latest") catch {
    err => fail("inspect failed: \{err}")
  }
  assert_eq(info.architecture, "amd64")

  let saved = source.save("example:latest") catch {
    err => fail("save failed: \{err}")
  }
  let parsed = @docker_cli.parse_docker_archive(saved) catch {
    err => fail("archive should parse: \{err}")
  }
  let entry = @docker_cli.primary_entry(parsed).unwrap()
  let layers = @docker_cli.extract_layers(saved, entry) catch {
    err => fail("layers should extract: \{err}")
  }
  assert_eq(layers.length(), 1)

  @docker_cli.remove_fake_cli(program)
  @docker_cli.remove_temp_bytes(archive_path)
}
```

## 能力

| 能力 | 入口 |
|---|---|
| 后端抽象 | `ImageSource`、`ImageBackend`、`DockerCliSource`、`EngineSource` |
| 探测与降级 | `default_candidates`、`probe_backends`、`resolve_backend`、`describe_backends` |
| 一步取归档 | `fetch_archive`、`fetch_archive_verbose` |
| 取归档进度 | `FetchStage`、`fetch_archive_verbose(on_stage=...)`、`save_or_pull_across_backends` |
| CLI 后端 | `save_args`、`inspect_args`、`run_cli`、`run_cli_to_file`、`DockerCliSource::save_to_file` |
| Engine 后端 | `http_over_unix`、`EngineSource::negotiate`、`EngineSource::pull`、`pull_error_of_stream` |
| 拉取策略 | `save_maybe_pulling`、`fetch_archive(pull_if_missing=true)`、`DockerCliSource::pull`、`pull_args` |
| unix 地址 | `parse_unix_uri`、`UnixUri` |
| docker-archive | `parse_docker_archive`、`extract_layers`、`primary_entry`、`layer_id_of` |

## 后端探测顺序

默认按这个顺序走，停在第一个可用的上：

```
DOCKER_HOST → CONTAINER_HOST → /var/run/docker.sock → /run/podman/podman.sock
           → docker → podman → nerdctl
```

两个 socket 变量都收：`DOCKER_HOST` 归 docker，`CONTAINER_HOST` 归 podman。
两者都接受 `unix://` 前缀与**裸绝对路径**（`/run/podman/podman.sock`），
指向同一条 socket 时只探一次。系统默认的两条 socket 一起排上——
容器环境里常只跑其中一只 daemon。

## 三个工具的差异

docker / podman / nerdctl 的 CLI「看起来一样」，实际有三处会把链路带歪，
都在 `cli_source.mbt` 里显式处理：

| | docker | podman | nerdctl |
|---|---|---|---|
| `save` 默认格式 | docker-archive ✅ | **oci-archive** ❌ 要 `--format docker-archive` | docker-archive ✅ |
| `inspect` 默认输出 | JSON ✅ | Go 模板表格 ❌ 要 `--format json` | JSON ✅ |
| 「本地没有」怎么说 | `No such image` | `image not known` | `no such object` / `not found` |

前两条是参数，第三条是**语义判定**：`ImageNotFound` 与 `Backend` 混了，
要么该拉的镜像被判死，要么拿一次注定失败的拉取盖住真正的原因。
三种原话都收（大小写不敏感），工具本身坏了（连不上 daemon、权限不够）
仍然算 `Backend`。

`pull` 三家参数一致，失败文案不一致——拉取失败一律报 `Backend` 带 stderr，
不翻成 `ImageNotFound`：「本地有没有」这件事只由 `inspect` 回答。

- `DOCKER_CLI=/opt/bin/docker` 显式指定时，把这个**文件**提到第一位。
  它是路径，不是「去 PATH 上找哪个名字」——PATH 上没有同名文件也照样能用
- `tcp://` / `ssh://` / `npipe://` 属于后续 issue，探测时直接跳过
  （返回 `None` 而不是给半成品实现）
- 顺序可配置：`default_candidates(env)` 返回的数组就是候选列表，调用方可以自己排

**Windows 上没有 socket 候选**（issue #94）：那边只有命名管道与 `tcp://`，
`/var/run/docker.sock` 必然不存在，所以默认候选只剩 `docker` / `podman` /
`nerdctl` 三个 CLI。路径分隔符也换：`PATH` 按 `;` 拆、`DOCKER_CLI` 的
`\` 也认，`docker.exe` 剥掉扩展名后一样能认出是哪个工具。
「一个后端都没有」的提示同样换成 Windows 的话术（Docker Desktop 的 bin 目录），
再让用户去设 `DOCKER_HOST=unix:///var/run/docker.sock` 等于让人去开一扇不存在的门。

平台判断不用 `#cfg`：被裁掉的分支在 Linux CI 上根本不编译，写错了等于没测。
改用运行时信息（`OS`、`pwd`／cwd 的盘符），两个平台走同一份代码，
`default_candidates_opts(env, windows_platform~)` 让测试把两边各钉一遍。

**探测只做「能不能用」的判定，不真的跑 `save`**：

- socket：先看文件类型，再发一个**有超时的** `_ping`。文件是 socket
  ≠ daemon 可用——CNB / 容器里 `/var/run/docker.sock` 常由外层转发进来，
  `connect(2)` 立刻成功但对端不通。不通就算这个候选不可用，让给后面的 CLI

**探测通过 ≠ 这条路推得动。** 转发进来的 socket 可能 `_ping` 答得好好的，
真去 `GET /images/{name}/get` 时才发现对端没有那个镜像——探测阶段看不出来。
所以选中的后端如果取不到归档，链路会顺着候选列表往下换一条再试
（`save_or_pull_across_backends` + `backend_chain`）：socket 不行就换 PATH 上的
docker，`DOCKER_CLI` 那个 docker 不行就换 socket。换路是**包的内部行为**，
调用方仍然只看到「一个镜像名 → 一个归档」。
- CLI：看 `PATH` 上解析不解析得到（再兜 `/usr/bin`、`/usr/local/bin` 等几个常见位置）

探测结果通过 `describe_backends` 一行一条打出来，排查时不用猜：

```
[ok] unix:///var/run/docker.sock: socket answers _ping
[no] docker: not found on PATH
```

## 超时

单次后端调用的默认超时是 **30 秒**（`default_timeout_ms`），不是「不设超时」。

这条默认值不是随手定的：`/var/run/docker.sock` 是转发进来的时候，
socket 在、`connect` 也成功，但对端不通——`timeout_ms = 0` 会让请求停在
「等状态行」上**永远不返回**，用户看到的是「跑起来完全没有任何输出」。
有超时才有一句能读的错误。

`cmd/main` 的 `--timeout <秒>` 可以调大它（比如拉几百 MB 的镜像）；
只认正整数，**不提供 0**——不留「挂死」那条路。

它只管 docker 调用。**取到归档之后的解压与叠树是纯本地计算，不受超时约束**，
在很大的层上本来就要花时间。`--verbose` 会把这段也播报出来
（`fetched N bytes` → `parsing archive (decompress + stack layers)...`），
免得中间那段沉默被当成卡死。

超时到点报的是 `Cancelled`（`<socket> was cancelled`）：一句「超时」。
不要让它变成「`connect failed: errno 2`」那种玄学——那既不像超时、
也不是你实际用的那条后端。一条路推不动换下一条时，**报第一条**（被选中的那条）
的原因，末尾那些够不着的兜底项不再顶上来；每条后端分别怎么了跟在后面。

## 错误语义

| 错误 | 场景 |
|---|---|
| `NoBackend(detail, probed)` | 一个后端都探不到，信息里逐条列出尝试过谁、为什么失败；第二个字段是同一份探测记录，供调用方判断「一个都没有」还是「有但取不到」（`no_backend_at_all`） |
| `ImageNotFound` | 后端答「本地没有这个镜像」——**不是故障**，可据此去拉 / 换路 |
| `Backend(name, code, stderr)` | 后端跑了但失败，子进程 stderr 原样透传 |
| `ExecutableNotFound` | 可执行文件不存在或无法 spawn |
| `Cancelled` | 超过 `timeout_ms`，子进程已被 cancel |
| `Archive` | docker-archive 解析失败 |
| `InvalidReference` | 空镜像名，在进子进程之前就拦下 |

无 daemon 环境（CI 常见）下探测失败只会得到明确的 `NoBackend` 与安装提示，不 panic。
`dive --from-image` 会就着 `no_backend_at_all` 把「这台机器根本没有 docker」
改判成「直连 registry 拉一次」（`--no-pull` 关掉这个兜底）。

## 本地没有就先拉

`pull` 是 `ImageSource` 的第三个方法（与 `inspect` / `save` 并列），
两条后端各自的实现：

- CLI 后端：`<tool> pull <ref>`
- Engine 后端：`POST /images/create?fromImage=<name>&tag=<tag>`

Engine 那条的响应是 `application/vnd.docker.raw-stream`，**HTTP 200 不代表拉成功**：
daemon 会在流里回 200 之后再吐 `{"errorDetail":{"message":"..."}}`。
`pull_error_of_stream` 逐行解析这些事件，抓到错误就报 `Backend`，否则会拿一个
「拉失败了但没人知道」的假成功去 `save`。老 daemon / 中间代理只回 `"error"` 字段，
也一并识别。

「本地没有就先拉」由 `save_maybe_pulling` 收口，**触发条件是 `inspect` 明确说没有**
（`ImageNotFound`：Engine 的 404、CLI 的 `No such image`），
不是「`save` 失败就拉」——`save` 的失败面太宽（daemon 卡住、权限、磁盘满），
一律去拉会用一次不必要的网络请求盖住真正的错误。
`inspect` 给出别的错（超时、连不上）说明**这条路本身不行**，该做的是换一条，
不是拉一次。

`cmd/main` 的默认就是「缺了就拉」（对齐原版 dive），`--no-pull` 关掉它，
`save_maybe_pulling(pull_if_missing=true/false)` 两端各对应一个开关。

```moonbit check
///|
async test "README pull example" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit"),
  ])
  let archive = @docker_cli.build_docker_archive([("beef", layer)])
  let archive_path = @docker_cli.write_temp_bytes("readme-pull.tar", archive)
  let dir = @fs.tmpdir(prefix="dive-readme-pull-")
  let log = "\{dir}/calls.log"
  // inspect 失败 = daemon 说本地没有；日志记下每次调用，好验证顺序
  let script = @docker_cli.fake_recording_cli(
    log,
    archive_path,
    "[]",
    inspect_code=1,
  )
  let (bin, _program) = @docker_cli.write_fake_cli_named("docker", script)
  let resolved = @docker_cli.resolve_backend(
    [@docker_cli.BackendCandidate::Cli(@docker_cli.CliTool::Docker)],
    { "PATH": bin },
  ) catch {
    err => fail("resolve failed: \{err}")
  }
  let saved = @docker_cli.save_maybe_pulling(
    resolved.backend,
    "nginx:latest",
    pull_if_missing=true,
  ) catch {
    err => fail("save_maybe_pulling failed: \{err}")
  }
  assert_eq(saved, archive)
  let calls = @fs.read_file(log).text()
  assert_true(calls.contains("pull nginx:latest"))
  assert_true(calls.find("pull nginx:latest") < calls.find("save nginx:latest"))

  @docker_cli.remove_fake_cli_dir(bin)
  @docker_cli.remove_fake_cli_dir(dir)
  @docker_cli.remove_temp_bytes(archive_path)
}
```

## 设计要点

- **超时包住整条链路**：`with_timeout_opt` 包的是「spawn + 读两个流 + wait」。
  只包 `wait` 会在「子进程写了 stdout 但不退出」时永远等不到超时。
- **父进程主动关写端**：`spawn` 之后立刻 `close` 父进程侧的管道写端，
  否则 `read_all` 等不到 EOF。
- **大归档不驻留内存**：`save_to_file` 让 stdout 直接走 `redirect_to_file`，
  数据不经过进程内存；`run_cli` 返回 `Bytes` 的形态只适合小镜像与测试。
- **HTTP 自己收口**：`moonbitlang/async/http` 面向 `http(s)://` URL，
  没有 unix socket 入口，所以包内收了一个最小 HTTP/1.1 客户端
  （状态行 + 头 + `Content-Length` / chunked）。
- **unix socket 自己建连**：`@socket.Tcp::connect_to_host` 内部先做 `getaddrinfo`，
  面向 `host:port`，连不上 `/var/run/docker.sock` 这种路径。
  `connect_unix_socket` 自己收口 `socket(AF_UNIX, ...)` + `connect(2)`，
  再把 non-blocking fd 交给 `@raw_fd.RawFdStream` 走事件循环收发。
- **`method` 改叫 `http_method`**：`method` 是 MoonBit 保留字。
- **只支持 native**：unix socket / `@raw_fd` / 子进程都只在 native 上有入口，
  本包因此声明 `supported_targets = "-all+native"`。只读 tar 的 P1–P4 不受影响。

## 测试策略

两条后端各自怎么验：

- **CLI 后端**：fake 可执行文件，不依赖真实 daemon（`cli_source_test.mbt`）
- **Engine 后端**：分两层
  - 报文层：请求组装 / 响应解析 / 版本前缀 / 引用编码 / 错误体提取（`engine_test.mbt`）
  - **传输层**：真起一根 unix socket、真发一次 HTTP、真读 chunked（`transport_test.mbt`）
- **大归档**：`save_to_file` 走流式路径，内存不随归档体积涨（`save_to_file_memory_test.mbt`）

### 测试用的 unix socket 服务端

`moonbitlang/async/socket` 只有 TCP / UDP 绑定，没有 `AF_UNIX` 的 listen / accept，
起不了 fake daemon。测试用一层薄 FFI 补上：

| 文件 | 作用 |
|---|---|
| `unix_socket_stub.c` | 生产侧：`connect(2)` 建连 |
| `unix_socket_test_stub.c` | 测试侧：`listen` / `accept` |
| `unix_test_support.mbt` | `UnixSocketServer`：起监听、等连接、收发字节 |

listen / accept 只服务测试，不进成品包的公开 API。
两个 stub 都只在 `#cfg(not(platform="windows"))` 下编译。

### 大 fixture 的生成方式

100MB 量级的归档不在仓库里（会把仓库撑爆），由 `large_fixture.mbt` 的
`write_large_archive(path, target_bytes)` **流式现造**：
按 tar 结构逐条写 header 与数据块，内存里只有 64KB 的填充缓冲，
无论目标多大都不驻留整段归档。

结构跟 `build_docker_archive` 一致（单层 `<id>/layer.tar` + config + `manifest.json`），
能被 `parse_docker_archive` 与 P2 的 `apply_layers_with_diffs` 直接吃下。

内存验证读 `/proc/self/status` 的 `VmRSS`：
写完之后当前占用不涨，就说明归档没被拼进内存。
（对照实验：走 `save` 的缓冲路径，100MB 归档会让 RSS 涨 ~127MB，用例会失败。）

## 与 P1–P4 的接线

`docker_cli` **不进入 P1–P4 的依赖链**：只用默认离线能力时，`dive x.tar` 的链路完全不受影响。
它只负责把「镜像名」变成「docker-archive tar」，落到既有的输入契约上：

```
镜像名 → save → docker-archive tar → parse_docker_archive → extract_layers
      → P2 apply_layers_with_diffs → P3 analyze_layers
```

端到端用例见 `pipeline_test.mbt`。

CLI 侧：`cmd/main` 用显式开关 `--from-image` 把位置参数当镜像名接到本包
（`moon run --target native cmd/main -- nginx:latest --from-image`），
本地缺镜像时默认先拉一次（对齐原版 dive），想纯离线就
`moon run --target native cmd/main -- nginx:latest --from-image --no-pull`；
取到归档后走既有的 `ImageSource::from_tar_bytes`；`--verbose` **边做边播报**
（`using <backend>` / `trying ...` / `saving ...`），结束后再补 `describe_backends`
的探测记录（`[ok]/[no]` 一行一条）与 `fetched N bytes`——全走 stderr。
不是「全部做完再回放一份日志」，那样读起来像倒放，中间还会突然安静。
端到端（fake docker，不依赖真实 daemon）见 `cmd/main/from_image_wbtest.mbt`，
说明见 [docs/p5-docker-cli.md](../docs/p5-docker-cli.md)。

## 许可与出处

- 后端探测与降级的思路来自 dive 的 `dive/image/docker/engine_resolver.go`（MIT）
- docker-archive 格式见 [docker save 文档](https://docs.docker.com/reference/cli/docker/image/save/)
- [Docker Engine API v1.4x](https://docs.docker.com/reference/api/engine/)（Apache-2.0）
