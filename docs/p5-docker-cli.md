# P5 `docker_cli` — 镜像名 → 本地归档

给「镜像名 → 本地 tar/layout」做两种后端：包装 `docker` / `podman` / `nerdctl` 的 CLI 后端，
和直连 `/var/run/docker.sock` 的 Engine 后端。产物统一收敛到 docker-archive，
喂给 P2/P3 的既有输入契约。

原始需求与验收清单见 [issue #17](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/17)；
「做不做 docker cli」的取舍过程见 [docker-cli-survey.md](docker-cli-survey.md)。

## 目标

1. **CLI 后端**：包装 `docker` / `podman` / `nerdctl` 可执行文件
   - `save <ref>` → 归档流
   - `inspect` → 镜像元信息（id / size / arch / os）
   - 行为等价、可互相降级
2. **Engine 后端**：走 HTTP over unix socket，不依赖 `docker` 可执行文件
   - unix socket 上的 HTTP/1.1 请求与响应（chunked + `application/vnd.docker.raw-stream`）
   - `GET /images/{name}/json`（inspect）
   - `GET /images/{name}/get`（save，流式归档）
   - `POST /images/create?fromImage=`（pull，含 raw-stream 错误判定）
   - `_ping` 做可用性探测与 API 版本协商

## 范围

### 后端抽象

```text
pub(open) trait ImageSource {
  async inspect(Self, String) -> ImageInfo raise DockerCliError
  async save(Self, String) -> Bytes raise DockerCliError
}
```

方法带 `async`：两条后端都要做阻塞 IO（起子进程 / 连 socket），
同步签名会把调用方逼进 `@async` 之外的不可能状态。

- 探测顺序可配置，默认：`DOCKER_HOST` → `/var/run/docker.sock` → PATH 上的 docker → podman → nerdctl
- 探测结果（用了哪个后端、为什么）通过 `describe_backends` 打印，一行一个候选
- 两条后端都失败时给出 `NoBackend` 与安装提示，而不是「命令找不到」

### CLI 后端

- 可执行文件发现：`DOCKER_CLI` 显式指定的**路径** → PATH 查找 → 常见安装路径兜底。
  `DOCKER_CLI` 是「用这个文件」，不是「去 PATH 上找这个名字」：
  它在候选里是独立的 `BackendCandidate::Program(路径, 工具)`，
  不再折回 `Cli(工具名)`——否则路径被丢掉，PATH 上没有同名文件时会
  报 `not found on PATH`，用户写死的程序根本不会被调用
- **不整体读进 `String`**：`run_cli` 走 `read_from_process` 拿 `Bytes`；
  `save_to_file` 再进一步，stdout 直接 `redirect_to_file`，大镜像不驻留内存
- 退出码与 stderr 透传：`Backend(name, code, stderr)`，排查不靠猜
- 超时与中断：`with_timeout_opt` 包住「spawn + 读两个流 + wait」，
  超时后 `hard_cancel()` 给子进程 SIGKILL
- **默认超时 30s**（`default_timeout_ms`），不是「不设超时」：
  `/var/run/docker.sock` 由外层转发时，socket 在、`connect` 也成功，
  但对端不通——没有超时就会停在「等状态行」上永远不返回（见 issue #42）。
  `cmd/main --timeout <秒>` 可调大，只认正整数

### Engine 后端

- unix socket HTTP：包内收了一个最小 HTTP/1.1 客户端
  （`moonbitlang/async/http` 面向 `http(s)://`，没有 unix socket 入口）
- 版本协商：`GET /_ping` 拿 `API-Version`，按版本拼 `/v1.4x/...` 前缀；
  老 daemon 不回该头时退回 `1.24`
- `GET /images/{name}/get` 响应是 tar 流，直接喂给 P2，不落盘
- `DOCKER_HOST`：只支持 `unix://`；`tcp://` / `ssh://` / context store 见「后续」
- **探测阶段真发一次 `_ping`**：socket 文件存在 ≠ daemon 可用。
  转发进来的 socket 会 accept 但不回，旧实现只看文件类型就判可用，
  之后的请求就悬住了。有界探活把这一步前移，不通就换候选

### 与四包的接线

- 产物统一收敛到既有输入格式：docker-archive tar，**不改 P1–P4 的输入契约**
- `cmd/main` 用 **显式开关** `--from-image` 把镜像名接到本包
  （见 [#28](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/28)）：

  ```bash
  # 显式声明「这是镜像名」，走本包取归档后再进 P2/P3/P4
  moon run --target native cmd/main -- nginx:latest --from-image
  # 后端与探测过程可见（选择 / 试哪条 / 拉 / 存 / [ok]|[no] 逐行，走 stderr）
  moon run --target native cmd/main -- nginx:latest --from-image --verbose
  # 本地缺镜像时默认先拉一次（对齐原版 dive）；--no-pull 关掉，纯离线绝不发网络请求
  moon run --target native cmd/main -- nginx:latest --from-image
  moon run --target native cmd/main -- nginx:latest --from-image --no-pull
  # 单次 docker 调用的超时（秒），默认 30；拉大镜像时调大
  moon run --target native cmd/main -- nginx:latest --from-image --timeout 300
  # 与既有开关组合，行为不变
  moon run --target native cmd/main -- nginx:latest --from-image --rules rules.json --format annotations
  ```

  取到归档后走既有的 `ImageSource::from_tar_bytes`，**不新开分析链路**。
  探测失败（`NoBackend` / `ExecutableNotFound` / `InvalidReference` / `Backend`）
  打人话 + 安装提示，不吞 docker 的 stderr，按「入参/环境不对」退 exit 2。
- **不做自动魔数嗅探**：只认显式 `--from-image`，避免「给个文件却去连 daemon」这种意外行为。
  原先设想的「探测顺序里自动识别镜像名」不再做。
- **本地缺镜像默认就拉**（对齐原版 dive，见 issue #44）：Go 版没有 `--pull` 开关，
  `ImageInspect` 报 not-found 就直接 `docker pull` 一次。这里同样把「缺了就拉」
  作为 `--from-image` 的默认行为，`--no-pull` 用来关掉（纯离线）。
  触发条件是 `inspect` 说本地没有，**不是**「`save` 失败了就拉」——
  `save` 的失败面太宽（daemon 卡住、权限、磁盘满），
  一律去拉会拿一次不必要的网络请求盖住真正的错误。
  本地已有时不多做一次 `pull`，一次 `inspect` 判缺失即可。
- 单独成包，**不进入 P1–P4 依赖链**；只用默认离线能力时 `dive x.tar` 的链路不受影响
- 本包只有 native 入口（子进程 / unix socket），因此 `cmd/main` 也声明
  `supported_targets = "-all+native"`；`--from-image` 的端到端覆盖见
  `cmd/main/from_image_wbtest.mbt`（fake docker 走 PATH 探测，不依赖真实 daemon）

## 排查：「跑起来没有任何输出」

`--from-image` 下有两处会表现成「卡住、什么都没打」，成因完全不同，
别混着猜（issue #42 来回了几轮才拆开）：

1. **取归档那一步超时** —— 转发进来的 socket `_ping` 答得好、`inspect`
   也答，但真去 `GET /images/{name}/get` 读 body 时对端没了。
   有 30s 默认超时兜底，到点报 `Cancelled`（`<socket> was cancelled`）。
   想更早看到就 `--timeout <秒>` 调小。
   报错只提**第一条**被选中的后端，末尾那条够不着的兜底项不再顶上来；
   每条后端分别怎么了跟着列在后面（也见 `--verbose` 的 `[ok]`/`[no]`）。

2. **归档解出来了，卡在分析** —— 这时候 `--verbose` 的四行头**已经打完**，
   说明取归档成功，后面的 gzip 解压 / 叠树还没完。
   `layer_tree` 自写的 inflate 曾在重叠回拷（`distance < length`）上退化成
   O(n²)：真实镜像 80MB 的层几十秒都出不来，看着就是挂死。
   已修为 O(n)（`copy_from_window` 用 `Buffer::view()` 而不是 `to_bytes()`）。

分界线就是那四行 `[docker]` 头：**打完了 = 取归档已经成功**，
问题在解压/分析；**没打完 = 还卡在取归档**，看第一条后端的错。

## 非目标

- `docker build` 封装
- 交互式 TUI
- 复刻 docker/cli 的 context store、`connhelper`（ssh/tls）、credential helper
- 100% Engine API 覆盖，只做「取到镜像」需要的端点
- `tcp://` / `ssh://` / `npipe://` 的 `DOCKER_HOST`（探测时显式跳过，返回 `None`）

## 验收对照

| 验收项 | 状态 | 落点 |
|---|---|---|
| CLI 后端对 docker / podman / nerdctl 三者，`inspect` + `save` 均有测试（可 fake） | ✅ | `cli_source_test.mbt`：fake 脚本 + 三者参数形态 |
| Engine 后端对 fake 服务端完成 inspect / save 测试，跑在 CI 里 | ✅ | `transport_test.mbt`：真起 unix socket 服务端，端到端跑通 |
| 无 daemon 环境下探测失败有明确错误与提示，不 panic | ✅ | `probe_test.mbt` 的 `NoBackend` 用例 |
| `docker save` 出来的 tar 能被 P2 的 `apply_layers_with_diffs` 直接吃下，端到端一个用例 | ✅ | `pipeline_test.mbt` |
| 大镜像走流式路径，不把整层读进内存 | ✅ | `save_to_file_memory_test.mbt`：100MB fixture + `/proc/self/status` |
| README 给出「后端探测 → inspect → save → 分析」的完整命令与预期输出 | ✅ | `docker_cli/README.mbt.md`（示例被测试跑一遍） |
| `cmd/main --from-image` 端到端跑出体积报告（可 fake CLI） | ✅ | `cmd/main/from_image_wbtest.mbt`：fake docker 走 PATH 探测 → 既有链路 |
| 无 daemon 时错误明确、exit 2、不 panic、不吞 stderr | ✅ | `cmd/main/from_image_wbtest.mbt` + `docker_cli/errors.mbt` 的 `Show` |
| 不给 `--from-image` 时行为完全不变 | ✅ | `cli_wbtest.mbt`：默认 `from_image=false`，走文件路径 |
| Engine `pull` 的 raw-stream 错误判定（`errorDetail` / `error`） | ✅ | `engine_test.mbt` + `transport_test.mbt` |
| `--from-image`（默认）本地缺失时先拉再取，已有则不动 | ✅ | `pipeline_test.mbt` + `cmd/main/from_image_wbtest.mbt` |
| `--no-pull` 绝不在本地缺镜像时拉取（纯离线） | ✅ | `cmd/main/from_image_wbtest.mbt` |
| socket 通 `_ping` 但取不到归档时换下一条候选；「没有镜像」与「后端坏了」分开 | ✅ | `transport_test.mbt` + `cli_source_test.mbt` |
| `moon check` / `moon test` 全绿 | ✅ | 582 个用例（native），见 `scripts/ci.sh` |
| CI 里有真实镜像 + 真实 CLI 后端的对拍 | ✅ | `scripts/docker-cli-probe.sh`：手搓最小 OCI layout → `docker load` → `inspect` / `save` / `--from-image` / `--from-registry` 四条通路 |

## CI 里的真实后端对拍

单元测试全用假 CLI（`fake_cli.mbt`）：证明解析逻辑对，证明不了
「我们敲的 `docker save` / `inspect` 和真 daemon 对得上」。参数形态写错、
docker 改了输出结构，假 CLI 一样全绿。

所以 `scripts/docker-cli-probe.sh` 补一层**真后端**对拍，接在
`scripts/ci.sh` 第 5 段：

- **测试镜像自己造**：手搓一份最小 OCI layout（单层 tar + `etc/dive-ci-marker`），
  `docker load` 进去。不依赖任何 base 镜像，CI 里没有「机器上有没有 alpine」这种不确定性。
- **不碰共享 daemon 的仓库名**：CNB 的 socket 常常是外层转发进来的，
  里面可能有别人的镜像。脚本只按 ID 操作自己 `load` 进去的那一个，跑完按名清掉。
- **四条通路**：`inspect` / `save` 的参数形态与归档结构 →
  `dive --from-image`（本地命中不联网、`--no-pull` 不许上网、缺了就拉）→
  `dive --from-registry`（不碰 daemon 的 registry 直拉）。
- **没有 daemon 就跳过**：脚本 exit 77，`scripts/ci.sh` 据此放行而不是判红。
  但「有 docker 却取不到镜像」必须是红的——那才是真问题。

## 遗留

原三件遗留里，前两件已在本轮落地（见 issue #25）：

1. ~~**fake unix socket 服务端**~~ → 用一层薄 FFI 补齐。
   `unix_socket_test_stub.c` 提供 listen / accept，
   `unix_test_support.mbt` 的 `UnixSocketServer` 起 fake daemon，
   `transport_test.mbt` 真发 HTTP、真读 chunked、真跑版本协商与 404 错误体。
   **顺带发现并修掉一个真实 bug**：`http_over_unix` 原先走
   `@socket.Tcp::connect_to_host`，它内部先做 `getaddrinfo`，
   永远连不上 `/var/run/docker.sock` 这种路径。现在换成
   `connect_unix_socket`（`socket(AF_UNIX)` + `connect(2)`）。
   本包因此只支持 native：`supported_targets = "-all+native"`。
2. ~~**`save_to_file` 的流式语义**~~ → `large_fixture.mbt` 的
   `write_large_archive` 流式现造 100MB 归档，
   `save_to_file_memory_test.mbt` 用 `/proc/self/status` 的 `VmRSS`
   断言写入后内存不随归档体积涨（对照实验：缓冲路径会涨 ~127MB，用例会失败）。
3. ~~**Engine 后端的 `pull`**~~ → 见 issue #42：
   `POST /images/create` 的 raw-stream **真解析**（`pull_error_of_stream`），
   HTTP 200 之后 daemon 吐的 `errorDetail` 不再被当成成功；
   `cmd/main --from-image` 本地缺镜像时默认先 `inspect` 判缺失、再 `pull`、最后 `save`
   （对齐原版 dive；`--no-pull` 关掉拉取）。进度事件本身仍不打日志（输出归调用方管）。
5. **「探测通过」不等于「这条路推得动」** → 见 issue #42 的第二层：
   转发进来的 socket 可以 `_ping` 答得好好的，真去取归档才发现对端没有镜像。
   现在选中的后端取不到归档时会顺着候选列表往下换一条
   （`save_or_pull_across_backends` / `backend_chain`），
   并新增 `DockerCliError::ImageNotFound` 把「后端说没有这个镜像」
   与「后端本身坏了」分开——前者该拉，后者该换路。
4. **`run_cli` 的 stdout / stderr 死锁** → 见 issue #44：
   原先「先读干 stdout、再读 stderr」，子进程一旦把 stderr 管道写满就会阻塞，
   永远不关 stdout，主进程卡在等 stdout 的 EOF。`docker pull` 的输出正好能到这个量级。
   现在两个流用 `group.spawn` **并发读干**，回归用例见 `exec_wbtest.mbt`。

## 测试基础设施

| 文件 | 作用 | target |
|---|---|---|
| `unix_socket_stub.c` | 生产侧 `connect(2)` 建连 | native |
| `unix_socket_test_stub.c` | 测试侧 `listen` / `accept` | native |
| `unix_test_support.mbt` | `UnixSocketServer`：起监听、等连接、收发字节 | native |
| `large_fixture.mbt` | 流式生成 100MB 量级 docker-archive | native |

两个 stub 都只在 `#cfg(not(platform="windows"))` 下编译；
`listen` / `accept` 只为测试服务，不进成品包的公开 API。

## 参考

- [Docker Engine API v1.4x](https://docs.docker.com/reference/api/engine/)（Apache-2.0）
- dive 的 `dive/image/docker/engine_resolver.go`（MIT）：后端探测与降级的原始思路
- [docker-cli-survey.md](docker-cli-survey.md)：生态调研（结论已按 P5 修订）
