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
| CLI 后端 | `save_args`、`inspect_args`、`run_cli`、`run_cli_to_file`、`DockerCliSource::save_to_file` |
| Engine 后端 | `http_over_unix`、`EngineSource::negotiate`、`EngineSource::pull` |
| unix 地址 | `parse_unix_uri`、`UnixUri` |
| docker-archive | `parse_docker_archive`、`extract_layers`、`primary_entry`、`layer_id_of` |

## 后端探测顺序

默认按这个顺序走，停在第一个可用的上：

```
DOCKER_HOST（unix://） → /var/run/docker.sock → docker → podman → nerdctl
```

- `DOCKER_CLI=/opt/bin/docker` 显式指定时会把它对应的候选提到第一位
- `tcp://` / `ssh://` / `npipe://` 属于后续 issue，探测时直接跳过
  （返回 `None` 而不是给半成品实现）
- 顺序可配置：`default_candidates(env)` 返回的数组就是候选列表，调用方可以自己排

**探测只看「能不能用」，不真的跑 `save`**：socket 看文件是不是 socket，
CLI 看 `PATH` 上解析不解析得到（再兜 `/usr/bin`、`/usr/local/bin` 等几个常见位置）。
探测结果通过 `describe_backends` 一行一条打出来，排查时不用猜：

```
[ok] unix:///var/run/docker.sock: socket exists
[no] docker: not found on PATH
```

## 错误语义

| 错误 | 场景 |
|---|---|
| `NoBackend` | 一个后端都探不到，信息里逐条列出尝试过谁、为什么失败 |
| `Backend(name, code, stderr)` | 后端跑了但失败，子进程 stderr 原样透传 |
| `ExecutableNotFound` | 可执行文件不存在或无法 spawn |
| `Cancelled` | 超过 `timeout_ms`，子进程已被 cancel |
| `Archive` | docker-archive 解析失败 |
| `InvalidReference` | 空镜像名，在进子进程之前就拦下 |

无 daemon 环境（CI 常见）下探测失败只会得到明确的 `NoBackend` 与安装提示，不 panic。

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
- **`method` 改叫 `http_method`**：`method` 是 MoonBit 保留字。

## 与 P1–P4 的接线

`docker_cli` **不进入 P1–P4 的依赖链**：只用默认离线能力时，`dive x.tar` 的链路完全不受影响。
它只负责把「镜像名」变成「docker-archive tar」，落到既有的输入契约上：

```
镜像名 → save → docker-archive tar → parse_docker_archive → extract_layers
      → P2 apply_layers_with_diffs → P3 analyze_layers
```

端到端用例见 `pipeline_test.mbt`。

## 许可与出处

- 后端探测与降级的思路来自 dive 的 `dive/image/docker/engine_resolver.go`（MIT）
- docker-archive 格式见 [docker save 文档](https://docs.docker.com/reference/cli/docker/image/save/)
- [Docker Engine API v1.4x](https://docs.docker.com/reference/api/engine/)（Apache-2.0）
