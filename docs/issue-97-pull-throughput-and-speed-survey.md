# 拉取吞吐与进度显示：调研（issue #97 后续）

用户问了两件事：

1. 「并发拉多层」和「边下边写盘」能不能做
2. 现在下载**没有速度和进度**，只有层的进度

第 2 点是**现在就成立的缺口**，不依赖前两点。第 1 点是两个可以分开做的改造。
本文只调研、不写代码。

## 0. 先说结论

| 诉求 | 能不能做 | 体量 | 有没有前置 |
|---|---|---|---|
| 速度 / 字节 / 整体百分比 | 能，小改 | 1 个新事件 + 渲染层取时间、回调加节流 | 无 |
| 并发拉多层 | 能，中改 | `pull.mbt` 主循环改成任务组 + 信号量，事件模型加层号 | 建议先做上面的进度 |
| 边下边写盘（OCI layout） | 能，中改 | `RegistryClient` 加流式读，`package.mbt` 分两块 | 无 |
| 边下边写盘（docker-archive） | 能，但**不可能变恒内存** | 同上 + 临时文件 + 回填 | 得先有流式读 |

顺序建议：**进度网格（0.1）→ 拉取并发（0.2）→ 流式落盘（0.3）**。
前两件是纯显示与调度，风险低、体感立竿见影；流式落盘动的是 IO 形状，
放在最后一轮，回归面才收得住。

## 1. 现场：为什么「只有层的进度」

现在的进度链路是完整的，缺的是**粒度**：

```
client.read_chunks  ──每 1 MiB──>  on_progress(received, length?)
        ↓
fetch_blob          ────────────>  PullEvent::LayerProgress(index, received, total)
        ↓
PullReporter.render ────────────>  "layer 7: 3.0 MiB / 244 MiB (1%) [overall 41%]"
```

四个具体问题：

**（a）没有速度。** `PullReporter` 里一个时间字段都没有
（`progress.mbt` / `reporter.mbt` 全文没有 `@clock` 之类的东西），
`progress_line` 的注释写着「画一行「第几层 已下/总量 百分比 速度」」，
但实际拼出来的字符串里没有速度。这不是渲染漏了，是**没人提供时刻**。

**（b）没有整体字节。** `overall_percent` 只在百分比上算，界面从不出现
「已下 300 MiB / 782 MiB」这种能让人估时间的信息。

**（c）表现取决于 content-length。** `fetch_blob` 的进度总量优先用
`content-length`，缺失就退回 descriptor 的 size。而
`client.read_chunks` 只在「累计值跨过 1 MiB 整数倍」时报一次：

```moonbit
if received - reported >= progress_step { ... }
```

**小于 1 MiB 的层永远一个 `LayerProgress` 都不会发**。issue #97 的现场日志
里 `layer 2: 0 B / 3.2 KiB (0%)`、`layer 5: 0 B / 446 B (0%)` 就是这个原因——
不是卡住，是报不出来。分块只有 64 KiB，所以上限是 16 次回调，但下限是 0 次。

**（d）看不到「在动」。** `on_tick`（→ `PullReporter.flush`）由
`read_chunks` 在**收到数据时**调用。一秒内一个字都没到，屏幕一秒内一个字节都不动，
用户无法区分「网慢」和「死了」。进度条能抖的前提是**定时器独立于数据**。

## 2. 改造一：速度与整体进度

### 2.1 事件侧：加一个「全局字节」

现在 `Plan` 给了总字节，`LayerProgress` 带层内 `received/total`，
渲染器自己维护 `done_bytes` 去凑整体。并发之后这套推算会崩（见 3.3），
不如让拉取侧把事实报全：

```moonbit
Plan(layers~, bytes~)
LayerStarted(index~, digest~, bytes~)
LayerProgress(index~, received~, total~)
/// 新增：整体已经拿到多少（压缩后字节，含正在下的那些层）
Progress(received~ : Int64, total~ : Int64)
```

`Progress` 由拉取侧统一算：`已完成层之和 + Σ 各层当前 received`。
单层串行时它等价于现在的 `done_bytes + received`，并发时仍然对。
渲染器从此不需要猜，只做减法算速度。

### 2.2 渲染侧：速度是渲染器的事

回调是同步的、拉取侧不该知道终端长什么样，所以：

- `PullReporter` 每次 `render` 记一个 `Clock` 时刻（`@async` 的 monotonic clock，
  别用墙钟：NTP 跳一下会算出负速度）
- 速度用**滑动窗口**（最近 1~2 秒的字节差 / 时间差），不用「总量 / 总耗时」：
  后者在 CDN 抖动时会长时间停在一个骗人的平均值上
- 首次刷新前没有基线，速度显示 `--`，别显示 `0 B/s`

目标形态（单行，`\r` 原地重画）：

```
layer 7/13  132 MiB / 244 MiB  54%  8.6 MiB/s  overall 41%  00:48 left
```

剩下的时间（ETA）是可选项：速度抖的时候 ETA 跳得比进度条还花，宁可先不做。

### 2.3 节流的两个数

现在有两个「步长」概念混在一起：

- `progress_step = 1 MiB`：**事件**粒度（`client.read_chunks`、
  `fetch_blob` 都引用它）
- 没有任何**渲染**粒度：`on_tick` 每跨 1 MiB 就写一次终端

第二个在大层上是灾难：244 MiB 的层 = 244 次 `\r` + `write(2)`，
而其实每秒 5 次就够人眼看了。建议：

- 事件粒度降到 `256 KiB`（分块是 64 KiB，正好 4 块一次；小层也能报出来）
- 渲染侧自限频：同一行的两次实际写入间隔 ≥ 200ms，最后一次强制刷
  （现在测试是直接数 `pending()` 的，加限频要同步改 `progress_test.mbt`）

**注意**：`fetch_blob` 里 config 是刻意不报进度的（层号会错位）。
这个决定别动。

### 2.4 计时器：让「卡住」看得见

`read_chunks` 目前在**数据到达时**才 `tick`。要显示「一直在动」，
得有一个与数据无关的心跳：

- 拉取主体外面 `@async.with_task_group`，起一个 `spawn_bg` 的循环：
  `@async.sleep(200ms)` → 重画
- 循环里只做「取状态 + 写终端」，不碰网络连接
- 任务组结构化收尾：拉取一结束（成功或失败）心跳自己停，不会留下野任务

这一条同时也是 §3 并发拉取的前置——现在的单线程串行循环里，
进度只可能在两次读之间推进。

### 2.5 收尾

- `Packing(note)` 现在只有一句静态文案。打包是 CPU 活，但它有确定的总量
  （各层未压缩长度之和），可以报百分比——顺带把「下载 100% 之后又卡住」这段盲区堵上
- 失败路径：`cmd/main/from_registry.mbt` 的 `catch` 里已经 `flush()` 了一次，
  但半行进度后面接错误信息仍然会糊在一起。收尾时补一个 `\n` + 一行
  「failed at layer 8/13 after 12.3s (8.6 MiB/s)」，把「下到哪一步断的」写清楚

## 3. 改造二：并发拉多层

### 3.1 现在为什么是串行

`pull_with_client` 就是一个 for 循环：

```moonbit
for index, descriptor in manifest.layers {
  let blob = fetch_blob(client, reference, descriptor, index, kind=LayerBlob, options~)
  layers.push(blob)
}
```

`layers` 的顺序 = manifest 顺序，这个顺序是**语义**（叠层顺序），不能因为并发而乱。

### 3.2 能借的东西：async 库已经齐了

不用自己写调度器，`moonbitlang/async@0.22.5` 提供了：

- `@async.with_task_group`：结构化并发，组退出时保证子任务都收尾
- `group.spawn` **返回 `Task[X]`，带 `value : Ref[X?]`**——天然是「并发跑、
  按原顺序取结果」，正好对上「层序不能乱」
- `@semaphore.Semaphore::new(size~=N)` + `acquire()`：限制在途层数
- `group.spawn_loop`：失败重试的现成形状（将来做断点续传用得上）
- 单个子任务失败时，**同组其余任务自动取消**——并发拉取的失败收尾几乎是白送的

### 3.3 改造面

`pull.mbt`：

- 循环体包进 `with_task_group`，每层一个 `spawn` 拿到 `Task`
- 用信号量卡住在途数，默认 **4**；`PullOptions` 加 `concurrency~ : Int32 = 4`，
  CLI 加 `--jobs`（0/1 = 现在的串行行为，保留一条退路）
- `spawn` 出来的结果按 manifest 顺序排回去，**顺序是契约**
- 目标平台 / manifest 选择完全不动

`progress.mbt` / `reporter.mbt`：这是并发真正要重排的地方。

- `LayerProgress` 本来就带 `index`，事件模型不用改
- `PullReporter` 现在是「一个 `current` 指针」：并发时事件会交错，
  必须改成 **`Map[Int32, LayerState]`**（每层一个 `received/total`）
- 新增的 `Progress(received, total)`（§2.1）承担整体口径，
  多层的整体进度不再靠「完成一层再加一层」累加
- `LayerDone` 的日志行会乱序出现（第 8 层可能先于第 7 层完成）。
  **接受它**——这是并发的事实；整体行才是进度条，逐层行只是日志

`auth` / token：

- 同一个 `RegistryClient` 的 token 是进程内的一个 `mut token`，
  并发下「同时 401 → 同时换票」会重复打 auth 服务（无害，但浪费）。
  稳妥做法是**在并发前先把票换好**（现在也是这么走的，第一次 401 已在
  manifest 请求里发生过），或给换票加一个一次性闸门
- 并发连接数要跟 `127.0.0.1` 上的假 registry 对齐：`@http.Server` 是单线程回调，
  在 `registry_test.mbt` 里并发拉 6 个层只是把请求排队，测不出真并发。
  要么机器上多起几个服务，要么只测「顺序没乱」而不测「真的并行」

失败收尾：

- 一层失败 → 任务组取消其余 → 已经被取消的层**不要**再发进度事件
- 半行的进程内 buffer 会残留：`PullReporter` 收尾要能「把所有层的最后已知状态」
  打出来，而不是只剩一个总百分比
- `RemoteImage` 的 `layers` 只可能要么全有、要么整个 `pull_image` 失败，
  这点不变（不做部分成功）

### 3.4 实际能快多少（要打预期）

- **单层镜像一点不快。** 244 MiB 的一层是个串行大块，并发帮不上
- 层数与大小分布决定上限。issue #97 那个镜像 13 层里 3 个大层（244/274/118 MiB）
  占了 636/782 MiB，理论上限约 2.2×
- 真实收益主要来自 **CDN 的每连接限速**与 **首字节延迟（TLS + 302 跳转）**：
  小层多的时候省下来的几乎全是 RTT，不是带宽
- 本地假 registry 上测不出加速（同一台机器、单线程 server），
  别拿它当性能证据

## 4. 改造三：边下边写盘

### 4.1 命门：现在正文必须整段落内存

`RegistryClient::get` 的注释写得很清楚：正文**必须在函数里读完**，
因为 native 后端的事件循环只保证「当前任务」手里的连接是活的，把没读完的应答
留到下一个挂起点就会读到失效的 fd（issue #97 那次 `Bad file descriptor`）。

`read_chunks` 的收尾更是硬拼一整块：

```moonbit
let result = FixedArray::make(total, b'\x00')   // total 来自 content-length
...
if received > 2147483647 { raise Network("... too large to hold in memory") }
```

所以「内存恒定」的前提是**先拆掉这个形状**，改成：

```moonbit
pub async fn RegistryClient::get_stream(
  self, path, headers~,
  sink : &@io.Writer,
  on_progress? : (Int64, Int64?) -> Unit,
) -> HttpStreamReply     // 只有状态 + 头，正文已经写进 sink
```

- 边读边写，中途不留 chunk 列表
- 状态码判定（401/404/307）在**开写之前**完成：`get_stream` 先拿响应头，
  判完了才决定写不写 sink。现在的重定向分支是「拿到整块应答再判 307」，
  顺序必须倒过来
- digest 校验改成流式：`@crypto.SHA256` 包一层 `HashingWriter`（`writer.mbt` 里已有）
- 一旦开始写盘，就没有「退回内存重试」的余地了，所以
  **重定向必须提前跟完**（307 → 新连接 → 才开始写）

### 4.2 OCI layout：可以直接恒内存

`write_oci_layout` 是把 `image.layers` 逐个 `@fs.write_file` 出去的，
这条路天然可以变成「读到哪写到哪」：

- blob 在 layout 里的文件名就是它**压缩后**的 digest（`blobs/sha256/<hex>`），
  而 manifest 里早就告诉了我们要下哪个 digest——**落盘前不需要整段数据**
- 已知的风险点：头里的大小 / digest 全对，但字节流中途断掉，
  磁盘上会留一个**名字对、内容坏**的 blob。而
  `ImageSource::load`（`image_ci/image.mbt:81`）读 OCI layout 时
  **不校验 digest**（源码注释明说「门禁阶段多一次哈希没有收益」）。
  于是下一次分析会安静地分析一份坏镜像
- 所以流式落盘必须配两件事：`File::size` 对一遍大小；
  或者干脆写到 `*.partial` 再 rename。后者更稳，代价是多一次 rename

这条是全套改造里**收益最大、风险最小**的一件：内存与镜像体积解耦，
而且顺手把 `image_ci` 里「整包读进 `Bytes`」的那一半也解掉了
（`read_oci_layout` 目前每个层一次 `read_file_to_bytes`）。

### 4.3 docker-archive：做不到「边下边写」，但能做到「不叠三份」

`package_docker_archive` 现在的顺序是：先把**所有层**解压一遍拿 diff id 与长度
（`HashingWriter` 只留 32 字节，这一步已经恒内存），再第二次解压写进 tar。
压缩态的 blob 仍然**全部在内存里**。

三种可能，按收益排序：

1. **落临时文件（推荐）**：blob 流式写进 `tmpdir` 里的一个文件，
   打包阶段用 `@fs.File::read_at` 按块读回来解压。内存恒定，
   且完全不动现有的打包语义（两遍扫描、diff id 校验、size 回填全都还在）。
   代价：多一次磁盘写；临时文件生命周期要跟 `errdefer` 绑死
   （`docker_cli/backend.mbt` 的 `TempArchive` 是现成的参考）
2. **只保留压缩 blob（不推荐）**：压缩比好的层留在内存、差的落盘。
   多一条分支、多一种行为，调试成本远大于省下的那点磁盘
3. **边下边解压边写 tar**：需要在 tar 里塞**占位 header**，最后一层解完再
   `seek` 回去改写 size 与 diff id。可行，但 diff id 必须与 config 对得上，
   对不上就得整份作废——这个「要么全对要么全废」的形状比临时文件苛刻得多

**结论**：docker-archive 的目录名是「解压后 tar 的 sha256」，这个约束不可能绕开，
所以「边下边写」在它这里只能以「边下边写临时文件」的形式存在。真正的
「网络字节直接进最终产物」只对 OCI layout 成立。

### 4.4 一个必须承认的连带代价

流式落盘之后，`pull_image` 不能再拿 `data.length()` 当大小、
`verify_digest` 也不能再对整个 `Bytes` 做。所有下游
（`package.mbt` 的两次 `diff_ids` 校验、`PulledBlob` 的 `data : Bytes`）
都得跟着换成「路径 + 大小 + digest」。这是本轮最大的一块连带改动，
建议单独一轮做，别和并发混在一起。

## 5. 验证怎么做

- **速度显示**：`PullReporter` 现在可以在测试里被喂事件，加时间注入
  （构造时传一个「假时钟」）就能断言速度与 ETA 的数值，不必睡真的时间
- **小层不再 0%**：造一个 3 KiB 的层，断言至少收到一个 `LayerProgress`
- **并发不串层**：假 registry 造 8 个小层，断言 `RemoteImage.layers`
  的顺序与 manifest 一致、每层 digest 校验通过
- **内存不随体积涨**：仓库里已有现成范式——`docker_cli/save_to_file_memory_test.mbt`
  用 `/proc/self/status` 的 `VmRSS` 卡 32MB 预算。流式落盘可以照抄一份
- **局部损坏要报**：假 registry 中途掐断连接，断言产物被删 / 不被当成功

## 6. 明确不做

- 断点续传 / 自动重试（`docs/p7-registry-cli.md` 第 5 节已划界，仍然不做）
- 打包与下载流水线并行（CPU 解压与网络 IO 叠加，收益小于复杂度，
  且会让「下载 100% 之后还要多久」更难说）
- 每层独立连接池调优、HTTP/2 多路复用（`@http.Client` 的选择，不在本仓收口）
