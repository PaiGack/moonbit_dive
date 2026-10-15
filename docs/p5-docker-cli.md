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
   - `POST /images/create?fromImage=`（pull，可选）
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

- 可执行文件发现：`DOCKER_CLI` 显式指定 → PATH 查找 → 常见安装路径兜底
- **不整体读进 `String`**：`run_cli` 走 `read_from_process` 拿 `Bytes`；
  `save_to_file` 再进一步，stdout 直接 `redirect_to_file`，大镜像不驻留内存
- 退出码与 stderr 透传：`Backend(name, code, stderr)`，排查不靠猜
- 超时与中断：`with_timeout_opt` 包住「spawn + 读两个流 + wait」，
  超时后 `hard_cancel()` 给子进程 SIGKILL

### Engine 后端

- unix socket HTTP：包内收了一个最小 HTTP/1.1 客户端
  （`moonbitlang/async/http` 面向 `http(s)://`，没有 unix socket 入口）
- 版本协商：`GET /_ping` 拿 `API-Version`，按版本拼 `/v1.4x/...` 前缀；
  老 daemon 不回该头时退回 `1.24`
- `GET /images/{name}/get` 响应是 tar 流，直接喂给 P2，不落盘
- `DOCKER_HOST`：只支持 `unix://`；`tcp://` / `ssh://` / context store 见「后续」

### 与四包的接线

- 产物统一收敛到既有输入格式：docker-archive tar，**不改 P1–P4 的输入契约**
- `cmd/main` 用 **显式开关** `--from-image` 把镜像名接到本包
  （见 [#28](https://cnb.cool/nrzhangsan/moonbit_dive/-/issues/28)）：

  ```bash
  # 显式声明「这是镜像名」，走本包取归档后再进 P2/P3/P4
  moon run --target native cmd/main -- nginx:latest --from-image
  # 后端与探测过程可见（[ok]/[no] 一行一条，走 stderr）
  moon run --target native cmd/main -- nginx:latest --from-image --verbose
  # 与既有开关组合，行为不变
  moon run --target native cmd/main -- nginx:latest --from-image --rules rules.json --format annotations
  ```

  取到归档后走既有的 `ImageSource::from_tar_bytes`，**不新开分析链路**。
  探测失败（`NoBackend` / `ExecutableNotFound` / `InvalidReference` / `Backend`）
  打人话 + 安装提示，不吞 docker 的 stderr，按「入参/环境不对」退 exit 2。
- **不做自动魔数嗅探**：只认显式 `--from-image`，避免「给个文件却去连 daemon」这种意外行为。
  原先设想的「探测顺序里自动识别镜像名」不再做。
- 单独成包，**不进入 P1–P4 依赖链**；只用默认离线能力时 `dive x.tar` 的链路不受影响
- 本包只有 native 入口（子进程 / unix socket），因此 `cmd/main` 也声明
  `supported_targets = "-all+native"`；`--from-image` 的端到端覆盖见
  `cmd/main/from_image_wbtest.mbt`（fake docker 走 PATH 探测，不依赖真实 daemon）

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
| `moon check` / `moon test` 全绿 | ✅ | 292 个用例（native），见 `scripts/ci.sh` |

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
3. **Engine 后端的 `pull`**：实现了 `POST /images/create`，但没有流式进度解析，
   也没有「本地缺失时自动 pull」的接线（范围外，另议）。

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
