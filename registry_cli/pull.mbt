///|
/// 一次拉取的可调项。
pub struct PullOptions {
  /// 目标平台；缺省取 `linux` + 当前编译架构（见 `host_platform`）
  platform : @oci_spec.Platform?
  /// `http://` + 跳过证书校验（命名与原版 docker 的 `--tls-verify=false` 语气一致）
  insecure : Bool
  /// 显式 token；缺省读 `DIVE_REGISTRY_TOKEN`
  token : String?
  /// 拉取进度（写 stderr / 画进度条由调用方负责，这里只回调事实）
  on_progress : ((PullEvent) -> Unit)?
  /// 每次报完进度后的「立刻画一下」：回调是同步的、写终端是 async 的，
  /// 不把这一格送到 async 上下文里，进度条就只能等下一层才动
  on_tick : (() -> Unit noraise)?
  /// 边下边写盘：层落到 `@fs.tmpdir` 下的临时文件里，内存不随镜像体积涨。
  ///
  /// 代价是「一次磁盘写 + 一次磁盘读」——OCI layout 直接把它抄过去，
  /// docker-archive 则要读回来解压。换来的是 700MB 的层不再要求一整块内存。
  stream_to_disk : Bool
  /// 同时在途的层数。1 = 老行为（逐层串行），0 也按 1 处理。
  ///
  /// 并发只对「多层小层」有收益：单层镜像一点不快，
  /// 省下来的大头是 CDN 的每连接限速与首字节延迟，不是带宽。
  concurrency : Int32
}

///|
/// 缺省值：本机平台、https、无 token、不打进度。
pub fn PullOptions::new(
  platform~ : @oci_spec.Platform? = None,
  insecure~ : Bool = false,
  token~ : String? = None,
  on_progress~ : ((PullEvent) -> Unit)? = None,
  on_tick~ : (() -> Unit noraise)? = None,
  concurrency~ : Int32 = 4,
  stream_to_disk~ : Bool = true,
) -> PullOptions {
  {
    platform,
    insecure,
    token,
    on_progress,
    on_tick,
    concurrency,
    stream_to_disk,
  }
}

///|
pub impl Show for PullOptions with fn to_string(self) {
  "PullOptions(insecure=\{self.insecure}, concurrency=\{self.concurrency}, stream_to_disk=\{self.stream_to_disk})"
}

///|
pub extend PullOptions with Show::{to_string, output}

///|
/// 拉下来的一个 blob：`digest` 是它自称的身份，`data` 是校验过的字节。
///
/// `data` 是**可选**的：走流式落盘时字节直接进了 `path` 上的文件，
/// 内存里只留 digest 与大小。这样 700MB 的层不会再要求一整块连续内存，
/// 下游（打包、分析）改成按路径流式读。
pub(all) struct PulledBlob {
  media_type : String
  digest : String
  /// 读进内存的那份字节；`None` 表示字节在 `path` 上
  data : Bytes?
  /// 压缩后的大小（manifest 里报的那个）
  size : Int64
  /// 流式落盘时字节所在的文件；`None` 表示在 `data` 里。
  /// 生命周期跟着 `RemoteImage`：`discard_image` 会把它删掉
  path : String?
} derive(Eq, Debug)

///|
/// 一个「字节都在内存里」的 blob（测试、小 blob、老调用方的写法）。
pub fn PulledBlob::in_memory(
  media_type~ : String,
  digest~ : String,
  data~ : Bytes,
) -> PulledBlob {
  {
    media_type,
    digest,
    data: Some(data),
    size: data.length().to_int64(),
    path: None,
  }
}

///|
/// 这个 blob 的字节：内存里那份，或者从 `path` 上按需读回来。
///
/// 只在「小 blob」与测试里用：真按这个读 700MB 的层，等于把流式落盘又退回内存。
pub async fn PulledBlob::bytes(self : PulledBlob) -> Bytes raise RegistryError {
  match self.data {
    Some(data) => data
    None =>
      match self.path {
        Some(path) => {
          let data = @fs.read_file(path) catch {
            err => raise Io("\{path}: \{err.to_string()}")
          }
          data.binary()
        }
        None => raise Io("blob \{self.digest} has neither bytes nor a file")
      }
  }
}

///|
/// 压缩后的大小。流式落盘的 blob 由 `size` 记着，内存里的由 `data` 量出来。
pub fn PulledBlob::compressed_size(self : PulledBlob) -> Int64 {
  match self.data {
    Some(data) => data.length().to_int64()
    None => self.size
  }
}

///|
pub extend PulledBlob with Eq::{equal, not_equal}

///|
pub extend PulledBlob with @debug.Debug::{to_repr}

///|
/// 从 registry 拉下来的完整镜像：config + 层，全是**压缩后的原始 blob**。
///
/// 保持压缩是有意的：打包成 OCI layout 时直接原样落盘，
/// 打包成 docker-archive 时才解压——解压成本不该由「只是搬运」的用法来付。
pub(all) struct RemoteImage {
  reference : ImageReference
  /// 选中的 manifest 的 media type（manifest 不是 index 时才有意义）
  media_type : String
  /// manifest 自身的 digest（index 里带出来的，或响应头给的）
  manifest_digest : String
  config : PulledBlob
  layers : Array[PulledBlob]
  /// 选中的平台（index 里有落到哪一项）
  platform : @oci_spec.Platform?
  /// 流式落盘时层所在的临时目录；`None` 表示字节都在内存里，无需清理
  staging : String?
} derive(Eq, Debug)

///|
pub extend RemoteImage with Eq::{equal, not_equal}

///|
pub extend RemoteImage with @debug.Debug::{to_repr}

///|
/// 从远端 registry 拉一个镜像。
///
/// 链路就是 three 步，没有任何 daemon 参与：
/// `token → manifest(index 按平台选) → config + layers`。
pub async fn pull_image(
  reference : ImageReference,
  options~ : PullOptions = PullOptions::new(),
) -> RemoteImage raise RegistryError {
  let token = match options.token {
    Some(token) => Some(token)
    None => @env.get_env_var("DIVE_REGISTRY_TOKEN")
  }
  // `connect` 现在自己报错（「连不上」与「机器没装 CA 包」不再是同一句话），
  // 这里原样往上抛，别把原因盖掉
  let client = RegistryClient::connect(
    reference.api_host(),
    insecure=options.insecure,
    token~,
  )
  let image = {
    errdefer client.close()
    pull_with_client(client, reference, options~)
  }
  client.close()
  image
}

///|
/// 用给定客户端拉取（测试可借此注入本地 registry 的地址与 token）。
pub async fn pull_with_client(
  client : RegistryClient,
  reference : ImageReference,
  options~ : PullOptions = PullOptions::new(),
) -> RemoteImage raise RegistryError {
  let platform = match options.platform {
    Some(platform) => platform
    None => host_platform()
  }
  notify(options, Started(reference=reference.canonical()))
  let tag = reference.reference
  let path = "/v2/\{reference.repository}/manifests/\{tag}"
  let accept = manifest_accept_header()
  let reply = get_authorized(client, path, accept, reference)
  if reply.status == 404 {
    raise NotFound(
      "\{reference.canonical()}: no manifest for \"\{tag}\" in \{reference.repository}",
    )
  }
  if reply.status != 200 {
    raise Network(
      "\{reference.canonical()}: manifest request answered \{reply.status}",
    )
  }
  // manifest 很小（几 KB），一次读完不心疼；层则一段一段读（见 `fetch_blob`）
  let manifest_body = reply.body
  // index 还是 manifest 看 Content-Type；头缺失时退回 body 里的 mediaType。
  // 不猜：真猜错会把 index 当 manifest 解析，症状是「config 字段是 undefined」
  let content_type = reply.header("content-type").unwrap_or("")
  let (manifest, manifest_digest, media_type, picked_platform) = choose_manifest(
    client, reference, reply, manifest_body, content_type, platform,
  )
  // 先把「要下多少」算出来：进度条没有总量就只能显示一个越滚越大的数字，
  // 用户依然不知道还要等多久（issue #97）
  let mut plan_bytes : Int64 = 0L
  for descriptor in manifest.layers {
    plan_bytes = plan_bytes + descriptor.size.to_int64()
  }
  notify(options, Plan(layers=manifest.layers.length(), bytes=plan_bytes))
  // 流式落盘的落点：放在临时目录，生命周期跟 `RemoteImage` 绑死
  let staging = if options.stream_to_disk {
    let directory = @fs.tmpdir(prefix="dive-blobs-") catch {
      err => raise Io("cannot create a staging directory: \{err}")
    }
    Some(directory)
  } else {
    None
  }
  // 拉一半失败：临时目录里的半截 blob 不能留着
  errdefer (match staging {
    Some(directory) => discard_directory(directory)
    None => ()
  })
  let (config, layers) = fetch_all(
    client,
    reference,
    manifest,
    options~,
    plan_bytes~,
    staging~,
  )
  {
    reference,
    media_type,
    manifest_digest,
    config,
    layers,
    // 只有从 index 里挑出来的才算「平台已知」：直接给 manifest 时
    // 服务端没说是哪个平台，硬记成请求参数只会让报告说谎（见 `choose_manifest`）
    platform: picked_platform,
    staging,
  }
}

///|
/// 把流式落盘的临时目录删掉；删不掉就算了，它本来就在 `/tmp` 下。
pub async fn discard_image(image : RemoteImage) -> Unit noraise {
  match image.staging {
    Some(directory) => discard_directory(directory)
    None => ()
  }
}

///|
async fn discard_directory(directory : String) -> Unit noraise {
  try @fs.rmdir(directory, recursive=true) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// 把 index 展开成真正的 manifest：平台匹配不到就报清楚「有哪几项可选」。
async fn choose_manifest(
  client : RegistryClient,
  reference : ImageReference,
  reply : HttpReply,
  manifest_body : Bytes,
  content_type : String,
  platform : @oci_spec.Platform,
) -> (@oci_spec.Manifest, String, String, @oci_spec.Platform?) raise RegistryError {
  let text = utf8(manifest_body)
  let header_digest = reply.header("docker-content-digest").unwrap_or("")
  let body_digest = @oci_spec.Digest::from_sha256(manifest_body).to_string()
  if @oci_spec.is_index_media_type(content_type) {
    let document = try @oci_spec.parse_document(text) catch {
      err =>
        raise Unsupported("index body is not valid JSON: \{err.to_string()}")
    } noraise {
      document => document
    }
    let index = match document {
      IndexDoc(index) => index
      other =>
        raise Unsupported(
          "server said index but the body is \{other.to_string()}",
        )
    }
    let chosen = select_platform(index, platform)
    // 子 manifest 一律按 digest 取：tag 会漂，digest 不会
    let child_path = "/v2/\{reference.repository}/manifests/\{chosen.digest}"
    let child = get_authorized(
      client,
      child_path,
      manifest_accept_header(),
      reference,
    )
    if child.status == 404 {
      raise NotFound(
        "platform manifest \{chosen.digest} is listed by the index but missing",
      )
    }
    if child.status != 200 {
      raise Network("manifest \{chosen.digest} answered \{child.status}")
    }
    let child_body = child.body
    let child_text = utf8(child_body)
    let manifest = parse_manifest(child_text)
    let media_type = child.header("content-type").unwrap_or("").to_string()
    return (
      manifest,
      non_empty_or(header_digest, body_digest),
      non_empty_or(media_type, chosen.media_type),
      // index 里那一项声明的平台才是权威：请求参数只是「想要什么」
      descriptor_platform(chosen),
    )
  }
  let manifest = parse_manifest(text)
  // 响应头优先：它才是 registry 认定的 digest（body 可能被重排过，但通常一致）
  (
    manifest,
    non_empty_or(header_digest, body_digest),
    non_empty_or(content_type.to_string(), manifest_media_type_of(manifest)),
    // 直接给 manifest：服务端没声明平台，config 里虽然有 architecture/os，
    // 但那是「镜像自称」，与「这个 tag 指向哪个平台」不是一回事，不填
    None,
  )
}

///|
fn descriptor_platform(
  descriptor : @oci_spec.Descriptor,
) -> @oci_spec.Platform? {
  descriptor.platform
}

///|
fn non_empty_or(primary : String, fallback : String) -> String {
  if primary.is_empty() {
    fallback
  } else {
    primary
  }
}

///|
fn manifest_media_type_of(manifest : @oci_spec.Manifest) -> String {
  match manifest.media_type {
    Some(media_type) => media_type
    None => @oci_spec.oci_manifest_media_type
  }
}

///|
fn parse_manifest(text : String) -> @oci_spec.Manifest raise RegistryError {
  let document = try @oci_spec.parse_document(text) catch {
    err => raise Unsupported("manifest is not valid JSON: \{err.to_string()}")
  } noraise {
    document => document
  }
  match document {
    @oci_spec.Manifest(manifest) => manifest
    other => raise Unsupported("expected a manifest, got \{other.to_string()}")
  }
}

///|
/// 在 index 里挑一个平台。
///
/// 优先精确匹配 os/arch/variant，其次忽略 variant，最后只有唯一候选才硬着头皮用。
/// 都不行就报错并**列出所有可选平台**——「manifest unknown」这种话
/// 除了让人去 Google 之外没有任何用处。
fn select_platform(
  index : @oci_spec.Index,
  platform : @oci_spec.Platform,
) -> @oci_spec.Descriptor raise RegistryError {
  let candidates : Array[@oci_spec.Descriptor] = []
  for descriptor in index.manifests {
    match descriptor.platform {
      // 没有 platform 的多半是 buildkit 的 attestation（`vnd.docker.reference.type`），
      // 选中它只会拿到一个空壳，所以跳过
      None => continue
      Some(entry_platform) =>
        if entry_platform.os == platform.os &&
          entry_platform.architecture == platform.architecture {
          candidates.push(descriptor)
        }
    }
  }
  if candidates.is_empty() {
    raise NotFound(
      "no \{platform.os}/\{platform.architecture} manifest in this index; available: \{describe_platforms(index)}",
    )
  }
  for descriptor in candidates {
    match descriptor.platform {
      Some(entry_platform) =>
        if entry_platform.variant == platform.variant {
          return descriptor
        }
      None => ()
    }
  }
  // 有 arch 没有 variant 歧义时直接用第一项（`linux/amd64` 多数镜像只有一个）
  candidates[0]
}

///|
fn describe_platforms(index : @oci_spec.Index) -> String {
  let parts : Array[String] = []
  for descriptor in index.manifests {
    match descriptor.platform {
      None => parts.push("<no platform>")
      Some(platform) =>
        parts.push(
          if platform.variant is Some(variant) {
            "\{platform.os}/\{platform.architecture}/\{variant}"
          } else {
            "\{platform.os}/\{platform.architecture}"
          },
        )
    }
  }
  if parts.is_empty() {
    "none"
  } else {
    parts.join(", ")
  }
}

///|
/// 拉 config 与所有层，**层序与 manifest 一致**（那是叠层顺序，属于语义，不能乱）。
///
/// 并发借的是 `@async` 的结构化并发：每层一个 `spawn` 拿到 `Task`，
/// 「并发跑、按原顺序取」正好对上「层序不能乱」；`Semaphore` 卡住在途层数，
/// 任务组退出时保证所有子任务都收尾，不留野连接。
///
/// **并发的是「谁在拉」，不是「一层的字节怎么读」**：真并行的前提是每条在途的层
/// 各占一条连接。`RegistryClient` 背后是一个 `@http.Client`，一次只服务一个请求
/// （单连接），两个任务共用它发请求会读到已经失效的 fd —— issue #97 的
/// `Bad file descriptor` 就是这个形状。所以并发时每层自己开一条，用完就关。
///
/// `concurrency <= 1` 时走原来的串行循环：共用一条连接，也是「怀疑并发」的退路。
async fn fetch_all(
  client : RegistryClient,
  reference : ImageReference,
  manifest : @oci_spec.Manifest,
  options~ : PullOptions,
  plan_bytes~ : Int64,
  staging~ : String? = None,
) -> (PulledBlob, Array[PulledBlob]) raise RegistryError {
  let in_flight = if options.concurrency < 1 { 1 } else { options.concurrency }
  if in_flight <= 1 {
    return fetch_all_serially(
      client,
      reference,
      manifest,
      options~,
      plan_bytes~,
      staging~,
    )
  }
  return fetch_all_concurrently(
    client,
    reference,
    manifest,
    options~,
    plan_bytes~,
    in_flight~,
    staging~,
  )
}

///|
/// 串行：一层下完再下一层，共用一个客户端（与老行为一致）。
async fn fetch_all_serially(
  client : RegistryClient,
  reference : ImageReference,
  manifest : @oci_spec.Manifest,
  options~ : PullOptions,
  plan_bytes~ : Int64,
  staging~ : String? = None,
) -> (PulledBlob, Array[PulledBlob]) raise RegistryError {
  // config 不是层：它不占层号，只报整体字节
  let config = fetch_blob(
    client,
    reference,
    manifest.config,
    0,
    kind=ConfigBlob,
    options~,
    staging~,
    plan_total_bytes=plan_bytes,
  )
  let layers : Array[PulledBlob] = []
  let mut done_bytes : Int64 = 0L
  for index, descriptor in manifest.layers {
    let blob = fetch_blob(
      client,
      reference,
      descriptor,
      index,
      kind=LayerBlob,
      options~,
      staging~,
      plan_done_bytes=done_bytes,
      plan_total_bytes=plan_bytes,
    )
    done_bytes = done_bytes + blob.compressed_size()
    layers.push(blob)
  }
  (config, layers)
}

///|
/// 并发：`in_flight` 层同时在途，结果按 manifest 顺序排回去。
///
/// 每一层（以及 config）都在自己的连接上跑：token 是同一个，
/// 但连接不共享——共享的 `@http.Client` 一次只服务一个请求。
///
/// 失败时不往上抛：`spawn` 里抛出去只会把同组其他层一起取消，而取消中的任务
/// 连在途名额都放不掉，收尾就成了「谁先死看运气」。这里把错误塞进数组，
/// 等所有层都停下来之后再统一报第一件出错的事。
async fn fetch_all_concurrently(
  client : RegistryClient,
  reference : ImageReference,
  manifest : @oci_spec.Manifest,
  options~ : PullOptions,
  plan_bytes~ : Int64,
  in_flight~ : Int32,
  staging~ : String? = None,
) -> (PulledBlob, Array[PulledBlob]) raise RegistryError {
  let gate = @semaphore.Semaphore(in_flight)
  let failures : Array[RegistryError] = []
  // 「已经下完多少」只能由调度这边记：各层自己算出来的是层内字节
  let finished_bytes : Ref[Int64] = { val: 0L, }
  let grouped = @async.with_task_group(group => {
    // config 不占在途名额：它是几十 KB 的一块，跟第一层挤在一起下最划算
    let config_task = group.spawn(() => {
      let outcome = Some(
        fetch_on_own_connection(client, own => {
          fetch_blob(
            own,
            reference,
            manifest.config,
            0,
            kind=ConfigBlob,
            options~,
            staging~,
            plan_total_bytes=plan_bytes,
          )
        }),
      ) catch {
        err => {
          failures.push(err)
          None
        }
      }
      outcome
    })
    let tasks : Array[@async.Task[PulledBlob?]] = []
    for index, descriptor in manifest.layers {
      gate.acquire()
      tasks.push(
        group.spawn(() => {
          let outcome = Some(
            fetch_on_own_connection(client, own => {
              let blob = fetch_blob(
                own,
                reference,
                descriptor,
                index,
                kind=LayerBlob,
                options~,
                staging~,
                plan_done_bytes=finished_bytes.val,
                plan_total_bytes=plan_bytes,
              )
              finished_bytes.val = finished_bytes.val + blob.compressed_size()
              // 层与层之间有空窗：报一次整体进度，进度行就不会定住
              match options.on_progress {
                Some(callback) =>
                  callback(
                    Progress(received=finished_bytes.val, total=plan_bytes),
                  )
                None => ()
              }
              blob
            }),
          ) catch {
            err => {
              failures.push(err)
              None
            }
          }
          gate.release()
          outcome
        }),
      )
    }
    // 按创建顺序取结果：`tasks` 的顺序就是 manifest 的顺序，层序因此不会乱
    let layers : Array[PulledBlob] = []
    for task in tasks {
      match task.wait() {
        Some(blob) => layers.push(blob)
        None => ()
      }
    }
    (config_task.wait(), layers)
  }) catch {
    err =>
      raise Network(
        "\{reference.canonical()}: pulling the layers failed: \{err.to_string()}",
      )
  }
  match failures {
    [first, ..] => raise first
    [] =>
      match grouped {
        (Some(config), layers) => (config, layers)
        // config 的失败本该被记进 `failures`；走到这里说明状态没对上，保守报一句
        (None, _) =>
          raise Network(
            "\{reference.canonical()}: the config blob was never fetched",
          )
      }
  }
}

///|
/// 在一条**专属**连接上跑一次取 blob。
///
/// `template` 只是用来抄 base 与 token：真正拨号的是这里新开的那个，
/// 用完必关（连接断了不会有人替它收 fd）。同一层要跟一次 307 到 CDN，
/// 那是 `get_following_redirects` 自己的事，与这里的「一条连接」不冲突。
async fn fetch_on_own_connection(
  template : RegistryClient,
  action : async (RegistryClient) -> PulledBlob raise RegistryError,
) -> PulledBlob raise RegistryError {
  let own = RegistryClient::connect(
    strip_scheme(template.base),
    insecure=template.base.has_prefix("http://"),
    token=template.token,
  )
  let blob = {
    errdefer own.close()
    action(own)
  }
  own.close()
  blob
}

///|
/// 这个 blob 是 config 还是层。
///
/// 只影响进度显示：config 通常几十 KB，把它算成「第 1 层」会让层号整体错位，
/// 而用户数层数是拿它跟 `dive --layer N` 对的。
priv enum BlobKind {
  ConfigBlob
  LayerBlob
}

///|
/// 按 descriptor 取一个 blob，并校验字节与 digest 一致。
///
/// `index` 是进度事件里的层号（config 用 0，第 i 层用 i + 1），
/// 只影响显示；读的时候一段一段读，顺手把「已经拿多少」报出去。
async fn fetch_blob(
  client : RegistryClient,
  reference : ImageReference,
  descriptor : @oci_spec.Descriptor,
  index : Int32,
  kind~ : BlobKind,
  options~ : PullOptions = PullOptions::new(),
  /// 字节落到哪个目录（`None` = 读进内存）。层大了、镜像大了，
  /// 内存不该跟体积一起涨——这是流式落盘的开关
  staging~ : String? = None,
  /// 已经下完的层加起来有多少字节（整体进度用）
  plan_done_bytes~ : Int64 = 0L,
  /// 整个镜像要下多少字节（整体进度用）
  plan_total_bytes~ : Int64 = 0L,
) -> PulledBlob raise RegistryError {
  let digest = descriptor.digest
  let path = "/v2/\{reference.repository}/blobs/\{digest}"
  let total = descriptor.size.to_int64()
  match kind {
    // config 不是层：不报层号，免得层号整体错位（`dive --layer N` 要对得上）
    ConfigBlob => ()
    LayerBlob => notify(options, LayerStarted(index~, digest~, bytes=total))
  }
  // 边下边报进度：回调直接给读正文的那一段（config 一般几十 KB，
  // 报层号只会把行刷乱，所以它只报整体）。
  // 层内的字节数要报，**整体**字节数更要报：渲染层靠「完成层之和 + 当前层」
  // 自己推算整体进度，多层并发时必然算错，所以把事实报全，让它只做减法。
  let progress = match options.on_progress {
    Some(callback) =>
      Some((received : Int64, length : Int64?) => {
        // 有 content-length 用它：重定向到 CDN 后可能与 descriptor 报的不同
        let reported_total = match length {
          Some(length) if length > 0 => length
          _ => total
        }
        // config 不占层号（那是 `dive --layer N` 要对上的），但它的字节要算进整体
        match kind {
          ConfigBlob => ()
          LayerBlob =>
            callback(LayerProgress(index~, received~, total=reported_total))
        }
        callback(
          Progress(received=plan_done_bytes + received, total=plan_total_bytes),
        )
      })
    None => None
  }
  let landed = match staging {
    Some(directory) =>
      download_to_file(
        client,
        path,
        reference,
        directory,
        digest~,
        declared=descriptor.size.to_int64(),
        options~,
        progress?,
      )
    None =>
      download_to_memory(
        client,
        path,
        reference,
        digest~,
        progress?,
        on_tick?=options.on_tick,
      )
  }
  // 字节数先对一遍：对不上就是截断，没必要再算 sha256（流式那边已经对过了）
  if descriptor.size > 0 && landed.size != descriptor.size.to_int64() {
    raise DigestMismatch(
      "blob \{digest}: descriptor says \{descriptor.size} bytes, got \{landed.size}",
    )
  }
  if landed.digest != digest {
    raise DigestMismatch(
      "blob \{digest}: content hash \{landed.digest} does not match",
    )
  }
  match kind {
    ConfigBlob => ()
    LayerBlob => notify(options, LayerDone(index~, bytes=landed.size))
  }
  {
    media_type: descriptor.media_type,
    digest,
    data: landed.data,
    size: landed.size,
    path: landed.path,
  }
}

///|
/// 一个 blob 落地的结果：字节在内存（`data`）或在文件（`path`），以及它的摘要。
priv struct LandedBlob {
  digest : String
  size : Int64
  data : Bytes?
  path : String?
}

///|
/// 读进内存。小 blob（config、测试里的层）走这条。
async fn download_to_memory(
  client : RegistryClient,
  path : String,
  reference : ImageReference,
  digest~ : String,
  progress? : (Int64, Int64?) -> Unit,
  on_tick? : () -> Unit noraise,
) -> LandedBlob raise RegistryError {
  let reply = get_following_redirects(
    client,
    path,
    reference,
    on_progress?=progress,
    on_tick?,
  )
  if reply.status == 404 {
    raise NotFound("\{reference.canonical()}: blob \{digest} is missing")
  }
  if reply.status != 200 {
    raise Network("blob \{digest} answered \{reply.status}")
  }
  let data = reply.body
  {
    digest: @oci_spec.Digest::from_sha256(data).to_string(),
    size: data.length().to_int64(),
    data: Some(data),
    path: None,
  }
}

///|
/// 边读边写盘，中途不留整段字节。
///
/// 先写 `*.partial` 再 rename：正文是流式的，断了就只剩半截文件；
/// 而下游（OCI layout 的 blob、docker-archive 的临时层）都只认「名字对 = 内容对」，
/// 半截的东西留着比删掉更难查。
async fn download_to_file(
  client : RegistryClient,
  path : String,
  reference : ImageReference,
  directory : String,
  digest~ : String,
  declared~ : Int64,
  options~ : PullOptions,
  progress? : (Int64, Int64?) -> Unit,
) -> LandedBlob raise RegistryError {
  guard declared > 0L else {
    // 没有大小就没法预估进度，也没法对账：退回内存，让上层照旧校验 digest
    return download_to_memory(
      client,
      path,
      reference,
      digest~,
      progress?,
      on_tick?=options.on_tick,
    )
  }
  let target = staged_blob_path(directory, digest)
  let partial = "\{target}.partial"
  // `tmpdir` 已经把目录建好了；这里只是兜住「调用方自己给了个目录」的情况
  @fs.mkdir(directory, recursive=true, allow_exist=true) catch {
    err => raise Io("\{directory}: \{err}")
  }
  // 连不上 / 读到一半断了：临时文件不该留在 staging 目录里
  errdefer remove_quietly(partial)
  let reply = get_stream_following_redirects(
    client,
    path,
    reference,
    partial,
    progress?,
    on_tick?=options.on_tick,
  )
  if reply.received != declared {
    remove_quietly(partial)
    raise DigestMismatch(
      "blob \{digest}: content-length says \{declared} bytes, got \{reply.received}",
    )
  }
  @fs.rename(partial, target, replace=true) catch {
    err => raise Io("\{target}: \{err}")
  }
  {
    digest: reply.digest,
    size: reply.received,
    data: None,
    path: Some(target),
  }
}

///|
/// 删文件，删不掉就算了：这里已经在报错的路上，再抛一个只会盖住真正的原因。
async fn remove_quietly(path : String) -> Unit noraise {
  try @fs.remove(path) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// staging 目录里一个 blob 的文件名。用 digest 的 hex 当名字：不同层不会撞，
/// 出事时一眼能看出这半个文件是谁的。
fn staged_blob_path(directory : String, digest : String) -> String {
  let colon = digest.find(":")
  let hex = match colon {
    Some(index) => digest[index + 1:].to_owned()
    None => digest
  }
  "\{directory}/\{hex}.blob"
}

///|
/// 与 `get_following_redirects` 同构，但正文边读边写盘。
///
/// 状态判定必须在**开写之前**：先拿头，判 307 / 404 / 200，再决定要不要写。
/// 现在的内存版是「拿到整块应答再判 307」，顺序反过来了——流式没有这个余地，
/// 开了写就没有「退回内存重试」这一说。
async fn get_stream_following_redirects(
  client : RegistryClient,
  path : String,
  reference : ImageReference,
  destination : String,
  progress? : (Int64, Int64?) -> Unit,
  on_tick? : () -> Unit noraise,
) -> StreamedBody raise RegistryError {
  let head = client.get_head(path)
  if head.status == 401 && !client.has_token() {
    // 换票必须发生在**开写之前**：一旦往盘上写了一半，
    // 就没有「换个 token 重来」的余地了
    let challenge_text = head.header("www-authenticate").unwrap_or("")
    let challenge = match parse_challenge(challenge_text) {
      Some(challenge) => challenge
      None =>
        raise Auth(
          "\{reference.canonical()}: 401 without a usable WWW-Authenticate header (\{challenge_text})",
        )
    }
    client.skip_body()
    client.set_token(fetch_token(client, challenge, reference))
    return get_stream_following_redirects(
      client,
      path,
      reference,
      destination,
      progress?,
      on_tick?,
    )
  }
  if head.is_redirect() {
    let location = head.header("location").unwrap_or("")
    if location.is_empty() {
      raise Network(
        "blob \{path} answered \{head.status} without a Location header",
      )
    }
    // 这条应答的正文不会再读了：丢掉它，连接才能接着用
    client.skip_body()
    let (origin, target) = resolve_location(client.base, location)
    let mirror = RegistryClient::connect(
      strip_scheme(origin),
      insecure=origin.has_prefix("http://"),
    )
    // 重定向的目标可能是几百 MB 的层：正文在这条连接上边读边写。
    // CDN 那边还可能再跳一次（S3、CloudFront 都会），所以这里先拿头再判。
    // 中间那条连接**没有**交给 `errdefer`：`mirror.close()` 必须在 return 之前
    // 真的执行到，否则每跳一次泄漏一条连接。
    errdefer mirror.close()
    let streamed = get_stream_following_redirects(
      mirror,
      target,
      reference,
      destination,
      progress?,
      on_tick?,
    )
    mirror.close()
    return streamed
  }
  if head.status == 404 {
    client.skip_body()
    raise NotFound("\{reference.canonical()}: blob \{path} is missing")
  }
  if head.status != 200 {
    client.skip_body()
    raise Network("blob \{path} answered \{head.status}")
  }
  // 200：正文接着在这条连接上读，不跳过
  stream_body(client, path, destination, progress?, on_tick?)
}

///|
/// 把这一条应答的正文写进 `destination`（先写 `.partial`，调用方负责 rename）。
async fn stream_body(
  client : RegistryClient,
  path : String,
  destination : String,
  progress? : (Int64, Int64?) -> Unit,
  on_tick? : () -> Unit noraise,
) -> StreamedBody raise RegistryError {
  let file = @fs.create(destination) catch {
    err => raise Io("\{destination}: \{err}")
  }
  let sink : &@io.Writer = file
  errdefer file.close()
  let streamed = client.read_stream(sink, on_progress?=progress, on_tick?)
  file.close()
  ignore(path)
  streamed
}

///|
/// blob 端点专用：307 到 CDN 时跟过去，但**不带** `Authorization`。
///
/// 分发凭据不该跟着重定向跑到 CDN 上（真实世界里那个 URL 是签名过的，
/// 再加一个 registry token 只会让对方困惑）；blob 本身是公开可读的字节。
async fn get_following_redirects(
  client : RegistryClient,
  path : String,
  reference : ImageReference,
  on_progress? : (Int64, Int64?) -> Unit,
  on_tick? : () -> Unit noraise,
) -> HttpReply raise RegistryError {
  let reply = get_authorized(client, path, "", reference)
  if !reply.is_redirect() {
    return reply
  }
  let message = reply.header("location").unwrap_or("")
  if message.is_empty() {
    raise Network(
      "blob \{path} answered \{reply.status} without a Location header",
    )
  }
  let (origin, target) = resolve_location(client.base, message)
  let mirror = RegistryClient::connect(
    strip_scheme(origin),
    insecure=origin.has_prefix("http://"),
  )
  // 重定向的目标可能是一个几百 MB 的层：进度要在这条连接上边读边报，
  // 所以回调是交给 `mirror.get` 的，而不是回来以后再补
  let followed = {
    errdefer mirror.close()
    mirror.get(target, on_progress?, on_tick?)
  }
  mirror.close()
  followed
}

///|
/// 只重放一次。要 token 的 registry 第一次就明说了；第二次还 401
/// 就说明凭据不对，再试只是把错误拖成超时。
async fn get_authorized(
  client : RegistryClient,
  path : String,
  accept : String,
  reference : ImageReference,
) -> HttpReply raise RegistryError {
  let headers : Map[String, String] = Map([])
  if !accept.is_empty() {
    headers.set("accept", accept)
  }
  let reply = client.get(path, headers~)
  if reply.status != 401 || client.has_token() {
    if reply.status == 401 {
      raise Auth(
        "\{reference.canonical()}: the registry rejected the token (401 on \{path})",
      )
    }
    return reply
  }
  let challenge_text = reply.header("www-authenticate").unwrap_or("")
  let challenge = match parse_challenge(challenge_text) {
    Some(challenge) => challenge
    None =>
      raise Auth(
        "\{reference.canonical()}: 401 without a usable WWW-Authenticate header (\{challenge_text})",
      )
  }
  if challenge.scheme != "bearer" {
    raise Auth(
      "\{reference.canonical()}: the registry asks for Basic auth, which needs a password; pass a token instead",
    )
  }
  let token = fetch_token(client, challenge, reference)
  client.set_token(token)
  let retry = client.get(path, headers~)
  if retry.status == 401 || retry.status == 403 {
    raise Auth(
      "\{reference.canonical()}: the token was rejected (\{retry.status} on \{path})",
    )
  }
  retry
}

///|
/// 拿挑战去换 token。
///
/// `realm` 是完整 URL，可能是另一个域名（Docker Hub 就是 auth.docker.io），
/// 所以这里单开一个只连 realm 的客户端，不复用 registry 那一个。
async fn fetch_token(
  client : RegistryClient,
  challenge : AuthChallenge,
  reference : ImageReference,
) -> String raise RegistryError {
  ignore(client)
  if challenge.realm.is_empty() {
    raise Auth("\{reference.canonical()}: Bearer challenge has no realm")
  }
  let (origin, path) = split_url(challenge.realm)
  let scope = if challenge.scope.is_empty() {
    "repository:\{reference.repository}:pull"
  } else {
    challenge.scope
  }
  let query = if challenge.service.is_empty() {
    "\{path}?scope=\{scope}"
  } else {
    "\{path}?service=\{challenge.service}&scope=\{scope}"
  }
  // origin 现在带协议（重定向需要），`connect` 只吃 host
  let token_client = RegistryClient::connect(
    strip_scheme(origin),
    insecure=origin.has_prefix("http://"),
  )
  // 换票失败也要关掉这条连接：它连的是 auth 服务，与 registry 不是同一个对象。
  // `errdefer` 只在抛错时触发，正常路径下面手动 close——两条路都得关。
  let reply = {
    errdefer token_client.close()
    token_client.get(query)
  }
  token_client.close()
  if reply.status != 200 {
    raise Auth(
      "\{reference.canonical()}: token endpoint answered \{reply.status}",
    )
  }
  // 换票应答也是正文：`get` 只收头，body 得自己读
  let body = reply.body
  let text = utf8(body)
  let json = @json.parse(text) catch {
    err => raise Auth("token endpoint returned non-JSON: \{err.to_string()}")
  }
  match json {
    Object(fields) =>
      match fields.get("token") {
        Some(String(token)) => token
        _ =>
          match fields.get("access_token") {
            Some(String(token)) => token
            _ =>
              raise Auth(
                "token endpoint returned neither token nor access_token",
              )
          }
      }
    _ => raise Auth("token endpoint returned a non-object")
  }
}

///|
/// `https://host/path` 拆成 `(协议 + host, path)`；只吃 http(s) 两种协议。
///
/// 返回的 origin 带协议：`RegistryClient::connect` 用它决定走不走 TLS，
/// 而重定向目标可能从 `https` 掉到 `http`（自建 registry），协议不能丢。
fn split_url(url : String) -> (String, String) raise RegistryError {
  let (scheme, rest) = if url.has_prefix("https://") {
    ("https://", url[8:].to_owned())
  } else if url.has_prefix("http://") {
    ("http://", url[7:].to_owned())
  } else {
    raise Auth("not an http(s) URL: \{url}")
  }
  match rest.find("/") {
    None => ("\{scheme}\{rest}", "/")
    Some(index) => ("\{scheme}\{rest[:index]}", rest[index:].to_owned())
  }
}

///|
/// manifest 端点要声明的类型：index 与 manifest 都列上，
/// 否则 registry 会挑一个它觉得好的（老版本会给你 schema 1 的 manifest）。
fn manifest_accept_header() -> String {
  [
    @oci_spec.oci_index_media_type, @oci_spec.docker_manifest_list_media_type, @oci_spec.oci_manifest_media_type,
    @oci_spec.docker_manifest_media_type,
  ].join(", ")
}

///|
fn utf8(data : Bytes) -> String {
  @encoding.decoder(UTF8).decode_lossy(data)
}

///|
fn notify(options : PullOptions, event : PullEvent) -> Unit {
  match options.on_progress {
    Some(callback) => callback(event)
    None => ()
  }
}

///|
/// 默认目标平台：`linux` + 当前编译架构。
///
/// 镜像分析场景里 `linux` 是几乎唯一的答案（容器就长在 linux 上），
/// 所以 os 写死；arch 跟着编译目标走，交叉分析时用 `--platform` 显式改。
pub fn host_platform() -> @oci_spec.Platform {
  {
    architecture: host_architecture(),
    os: "linux",
    os_version: None,
    os_features: None,
    variant: None,
  }
}

///|
/// 当前编译架构的 registry 叫法。
///
/// 没有现成的运行时探测（MoonBit 的 `@env` 只给环境变量），
/// 所以走编译期分支：native 后端在 x86_64 与 aarch64 上最多，
/// 其余架构留一个环境变量口子，别硬猜。
fn host_architecture() -> String {
  match @env.get_env_var("DIVE_PLATFORM_ARCH") {
    Some(arch) => arch
    None => default_architecture()
  }
}

///|
fn default_architecture() -> String {
  target_architecture()
}

///|
/// 去掉 `https://` / `http://` 前缀：`RegistryClient::connect` 只吃 host。
fn strip_scheme(origin : String) -> String {
  if origin.has_prefix("https://") {
    origin[8:].to_owned()
  } else if origin.has_prefix("http://") {
    origin[7:].to_owned()
  } else {
    origin
  }
}
