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
}

///|
/// 缺省值：本机平台、https、无 token、不打进度。
pub fn PullOptions::new(
  platform~ : @oci_spec.Platform? = None,
  insecure~ : Bool = false,
  token~ : String? = None,
  on_progress~ : ((PullEvent) -> Unit)? = None,
  on_tick~ : (() -> Unit noraise)? = None,
) -> PullOptions {
  { platform, insecure, token, on_progress, on_tick, }
}

///|
pub impl Show for PullOptions with fn to_string(self) {
  "PullOptions(insecure=\{self.insecure}, token=\{self.token is Some(_)})"
}

///|
pub extend PullOptions with Show::{to_string, output}

///|
/// 拉下来的一个 blob：`digest` 是它自称的身份，`data` 是校验过的字节。
pub(all) struct PulledBlob {
  media_type : String
  digest : String
  data : Bytes
} derive(Eq, Debug)

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
  let client = RegistryClient::connect(
    reference.api_host(),
    insecure=options.insecure,
    token~,
  ) catch {
    _ =>
      raise Network("cannot create an HTTP client for \{reference.api_host()}")
  }
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
  let manifest_body = reply.read_body()
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
  // config 不是层：它不占层号，事件里单独说一声，进度条只算层
  let config = fetch_blob(
    client,
    reference,
    manifest.config,
    0,
    kind=ConfigBlob,
    options~,
  )
  let layers : Array[PulledBlob] = []
  for index, descriptor in manifest.layers {
    let blob = fetch_blob(
      client,
      reference,
      descriptor,
      index,
      kind=LayerBlob,
      options~,
    )
    layers.push(blob)
  }
  {
    reference,
    media_type,
    manifest_digest,
    config,
    layers,
    // 只有从 index 里挑出来的才算「平台已知」：直接给 manifest 时
    // 服务端没说是哪个平台，硬记成请求参数只会让报告说谎（见 `choose_manifest`）
    platform: picked_platform,
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
    let child_body = child.read_body()
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
) -> PulledBlob raise RegistryError {
  let digest = descriptor.digest
  let path = "/v2/\{reference.repository}/blobs/\{digest}"
  let total = descriptor.size.to_int64()
  match kind {
    // config 不是层：不报层号，免得层号整体错位（`dive --layer N` 要对得上）
    ConfigBlob => ()
    LayerBlob => notify(options, LayerStarted(index~, digest~, bytes=total))
  }
  let reply = get_following_redirects(client, path, reference)
  if reply.status == 404 {
    raise NotFound("\{reference.canonical()}: blob \{digest} is missing")
  }
  if reply.status != 200 {
    raise Network("blob \{digest} answered \{reply.status}")
  }
  let data = match kind {
    // config 一般几十 KB，报进度只会把行刷乱
    ConfigBlob => reply.read_body()
    LayerBlob =>
      match options.on_progress {
        None => reply.read_body()
        Some(callback) =>
          reply.read_body_with(
            on_progress=(received, length) => {
              // 有 content-length 用它：重定向到 CDN 后可能与 descriptor 报的不同
              let total = match length {
                Some(length) if length > 0 => length
                _ => total
              }
              callback(LayerProgress(index~, received~, total~))
            },
            on_tick?=options.on_tick,
          )
      }
  }
  // 字节数先对一遍：对不上就是截断，没必要再算 sha256
  if descriptor.size > 0 && data.length() != descriptor.size {
    raise DigestMismatch(
      "blob \{digest}: descriptor says \{descriptor.size} bytes, got \{data.length()}",
    )
  }
  if !@oci_spec.verify_digest(data, digest) {
    raise DigestMismatch(
      "blob \{digest}: content hash \{@oci_spec.Digest::from_sha256(data)} does not match",
    )
  }
  match kind {
    ConfigBlob => ()
    LayerBlob =>
      notify(options, LayerDone(index~, bytes=data.length().to_int64()))
  }
  { media_type: descriptor.media_type, digest, data, }
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
  ) catch {
    _ => raise Network("cannot create an HTTP client for \{origin}")
  }
  let followed = {
    errdefer mirror.close()
    mirror.get(target)
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
  ) catch {
    _ => raise Network("cannot create an HTTP client for the token endpoint")
  }
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
  let body = reply.read_body()
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
