///|
/// `dive` 的只读分析入口：`dive <image|archive> [--rules rules.json] [--layer N] [--path P] [--efficiency]`。
///
/// 链路是 P1/P2 → P3 → P4 的串接：
///
/// 1. 拿到镜像归档（本地 tar / OCI layout / stdin，或者一个镜像引用）
/// 2. 逐层解压后喂给 `layer_tree` 叠树
/// 3. `image_analysis` 出体积报告
/// 4. `image_ci` 按规则判定，输出人类可读 / JSON / CI 注解
///
/// **位置参数自己说它是什么**（issue #124），不再靠 `--from-image` /
/// `--from-registry` 两个开关挑路：
///
/// - `-` → stdin
/// - 路径存在（文件或目录）→ 本地归档 / OCI layout，一步都不碰网络
/// - 其余 → 当成镜像引用
///
/// 「镜像引用」这一档里先问 docker（`inspect` 说本地有就 `save`，说没有就先 `pull`
/// 一次再 `save`），**这台机器上一个 docker 后端都没有**时才自己连 registry
/// （issue #109）。两条路的产物都是 docker-archive tar，谁拿到就谁往下走。
///
/// `--no-pull` 一句话：本次运行绝不发起任何出网请求。`inspect` / `save` 是纯本地操作，
/// 照常执行；只有 `pull` 与 registry 直拉被拦下。
///
/// `--layer` / `--path` / `--aggregate` / `--efficiency` 是 dive 交互界面的只读替身：
/// 没有 TUI，但能逐层看文件树、按目录下钻、按「多写了几份」看哪条路径拖了效率。
/// 给了 `--layer` / `--aggregate` 或 `--efficiency` 就不做门禁判定，只打印对应的那张表。
///
/// `--aggregate` 对齐原版 dive 的 `Ctrl+A`：diff 换成「相对第 0 层之前的整段累积」
/// （范围内被改回的路径也算 `modified`），不给这个开关时行为完全不变。
///
/// 退出码由 `image_ci` 定义：`0` 全过、`1` 有规则未通过、
/// `2` 规则非法或镜像读不出来。wasm 下拿不到退出码，详见 `exit.mbt`。
async fn main {
  let matches = cli().parse() catch {
    // argparse 的报错里已附用法，直接打出来，按「入参不对」退出
    err => {
      eprintln(err.to_string())
      exit_process(@image_ci.exit_config_error)
      return
    }
  }
  let options = Options::from_matches(matches)
  // `--save` 是「只取不分析」：把镜像落成 tar / OCI layout 就结束，不走进分析链路。
  // 先于 `load_source` 判定，免得为了保存去解一遍镜像
  if options.save {
    save_only(options) catch {
      err => {
        report_error(err)
        exit_process(@image_ci.exit_config_error)
      }
    }
    exit_process(@image_ci.exit_ok)
  }
  // 判定在前（见 `load_source`）：本地路径直接读文件，镜像引用才去连 docker / registry。
  // 取归档是 async，读文件与分析都是同步的，取到字节后走进同一条链路。
  let source = load_source(options) catch {
    err => {
      report_error(err)
      exit_process(@image_ci.exit_config_error)
      return
    }
  }
  // `--tui` 走交互式看树：它不是「一份报告」，而是把同一批数据接成可上下走的视图，
  // 因此单独一条分支，不混进 `run` 的判定链路。退出码只有 0 / 2。
  if options.tui {
    run_tui(options, source) catch {
      err => {
        report_error(err)
        exit_process(@image_ci.exit_config_error)
      }
    }
    exit_process(@image_ci.exit_ok)
  }
  try run(options, source) catch {
    error => {
      report_error(error)
      exit_process(@image_ci.exit_config_error)
    }
  } noraise {
    code => exit_process(code)
  }
}

///|
/// `--tui` 分支：打开全屏交互式看树（路径 B）。
///
/// 数据全部来自既有链路（`decompress_layers` + `browse_decompressed`
/// + `analyze_decompressed`），这里只做「解压一遍 → 建视图状态 → 进主循环」。
/// 终端不可用时按「运行错误」退 2——而不是静默回落到文本输出，
/// 否则脚本里 `--tui` 会莫名其妙地变成一条一次性的报告。
///
/// 全屏的进出由 `@tui.run_app` 自己管（进 alternate screen、退出还原），
/// 这里只提供「raw mode」这一层保护：两者都失效才会把终端留在坏状态。
async fn run_tui(
  options : Options,
  source : @image_ci.ImageSource,
) -> Unit raise CommandError {
  let tty = @tty.Tty::stdio() catch {
    _ =>
      raise CommandError::Analysis(
        "--tui needs a terminal (stdio is not a tty)",
      )
  }
  if source.layers.is_empty() {
    raise CommandError::Image("image has no layers")
  }
  let layers : Array[BytesView] = []
  for layer in source.layers {
    let raw = layer.raw_bytes() catch {
      err => raise CommandError::Image(err.to_string())
    }
    layers.push(raw)
  }
  // 先解压一遍，再让两条链路共用它：逐层快照（`browse_decompressed`）
  // 与跨层统计（`analyze_decompressed`）。解压是 TUI 启动里最贵的一步，
  // 没有理由为同一批层做两遍（issue #52）。
  let decompressed = @layer_tree.decompress_layers(layers) catch {
    err => raise CommandError::Analysis(err.to_string())
  }
  let views = @layer_tree.browse_decompressed(decompressed)
  // 详情面板的数字来自一次完整分析；拿不到就退化成「没有详情」，画面照常可用
  let details = match @tui.analysis_of_decompressed(decompressed) {
    Some((analysis, report)) => Some(@tui.detail_source_of(analysis, report))
    None => None
  }
  let initial_layer = match options.layer {
    Some(layer) => layer
    None => views.length() - 1
  }
  let state = @tui.AppState::new(views, details, options.image, initial_layer~)
  // `with_raw_mode` 保证退出时把终端状态还原，哪怕主循环里抛错；
  // alternate screen 的还原由 `run_app` 的 defer 管（见 `tui/alt_screen.mbt`）。
  // 它自己会抛 OSError（终端状态拿不到时），统一折成「分析错误」好让退出码收敛。
  tty.with_raw_mode(() => @tui.run_app(tty, state)) catch {
    err =>
      raise CommandError::Analysis("cannot run the interactive browser: \{err}")
  }
}

///|
/// 命令行定义。
fn cli() -> @argparse.Command {
  @argparse.Command(
    "dive",
    about="analyze an OCI image and enforce size rules",
    version="0.1.0",
    options=[
      @argparse.OptionArg(
        "rules",
        short='r',
        about="rules json to enforce (default: analysis only)",
      ),
      @argparse.OptionArg(
        "format",
        short='f',
        about="output format: text, json, html or annotations",
        default_values=["text"],
      ),
      @argparse.OptionArg(
        "output",
        short='o',
        about="write the report to a file instead of stdout (html only, for now)",
      ),
      @argparse.OptionArg(
        "layer",
        short='l',
        about="show the file tree as of layer N (0-based) instead of the gate",
      ),
      @argparse.OptionArg(
        "path",
        short='p',
        about="restrict the tree/efficiency view to a subtree (default layer: last)",
      ),
      @argparse.OptionArg(
        "top",
        about="how many paths the efficiency view lists (0 = all, default: 10)",
        default_values=["10"],
      ),
      @argparse.OptionArg(
        "timeout",
        about="seconds a docker call may go without any output (default: 30)",
      ),
      @argparse.OptionArg(
        "archive-format",
        about="with --save: output format, docker-archive (default) or oci",
        default_values=["docker-archive"],
      ),
      @argparse.OptionArg(
        "platform",
        about="image reference: target platform, os/arch[/variant] (default: linux + this machine's arch)",
      ),
      @argparse.OptionArg(
        "registry-token",
        about="registry bearer token for image pulls (default: $DIVE_REGISTRY_TOKEN)",
      ),
      @argparse.OptionArg(
        "jobs",
        about="how many layers to download from the registry at once (default: 4, 1 = one at a time)",
        default_values=["4"],
      ),
    ],
    flags=[
      @argparse.FlagArg(
        "efficiency",
        about="show per-path efficiency (cumulative - min), sorted desc, instead of the gate",
      ),
      @argparse.FlagArg(
        "save",
        about="only save the image reference to --output, do not analyze it",
      ),
      @argparse.FlagArg(
        "no-pull",
        about="never touch the network in this run: no docker pull, no registry fetch",
      ),
      @argparse.FlagArg(
        "verbose",
        about="print the docker/registry backend log to stderr",
      ),
      @argparse.FlagArg(
        "tui",
        about="open the interactive layer browser (native only, needs a real terminal)",
      ),
      @argparse.FlagArg(
        "aggregate",
        about="with --layer, compare that layer against the start of the image instead of its parent",
      ),
      @argparse.FlagArg(
        "insecure-registry",
        about="image reference against a plain-http registry (also skips TLS verification)",
      ),
    ],
    positionals=[
      @argparse.PositionArg(
        "image",
        about="docker save tar, OCI layout directory, - for stdin, or an image reference like nginx:latest",
      ),
    ],
  )
}

///|
/// 解析出来的选项。
struct Options {
  image : String
  rules : String?
  format : String
  output : String?
  layer : Int32?
  path : String?
  efficiency : Bool
  /// `--no-pull`：本次运行绝不发起网络请求。
  ///
  /// 拦的只有「需要出网」的那两步——`docker pull` 与 registry 直拉；
  /// `inspect` / `save` 是纯本地操作，照常执行。
  no_pull : Bool
  /// 打 `docker_cli` 的后端探测记录
  verbose : Bool
  /// 打开交互式看树（native only）
  tui : Bool
  /// `--aggregate`：`--layer` 视图把 diff 换成「相对第 0 层之前的整段累积」
  /// （对齐原版 dive 的 `Ctrl+A` / 聚合档）。只影响 `--layer` 分支，
  /// 不给这个开关时输出与从前逐字节一致
  aggregate : Bool
  /// `--save`：只落盘，不做分析。只对镜像引用生效——输入已经是本地归档时无从谈起
  save : Bool
  /// 落盘格式：`docker-archive`（默认）或 `oci`
  archive_format : @registry_cli.ArchiveFormat
  /// 目标平台 `os/arch[/variant]`
  platform : String?
  /// `--insecure-registry`：走 `http://` 并跳过证书校验（自建 registry）
  registry_insecure : Bool
  /// `--registry-token`：显式 token，缺省读 `DIVE_REGISTRY_TOKEN`
  registry_token : String?
  /// `--jobs`：同时在途的层数（1 = 逐层串行）
  jobs : Int32
  top : Int32
  /// 单次 docker 调用的超时（毫秒）。刻意**不接受 0**：
  /// 无超时正是「半死 socket → 静默挂住」的老问题，不给用户留这个坑
  docker_timeout_ms : Int32
} derive(Debug)

///|
fn Options::from_matches(matches : @argparse.Matches) -> Options {
  {
    image: first_value(matches, "image"),
    rules: optional_value(matches, "rules"),
    format: {
      let format = first_value(matches, "format")
      if format == "" {
        "text"
      } else {
        format
      }
    },
    output: optional_value(matches, "output"),
    layer: layer_of(matches),
    path: optional_value(matches, "path"),
    efficiency: flag_of(matches, "efficiency"),
    no_pull: flag_of(matches, "no-pull"),
    verbose: flag_of(matches, "verbose"),
    tui: flag_of(matches, "tui"),
    aggregate: flag_of(matches, "aggregate"),
    save: flag_of(matches, "save"),
    archive_format: archive_format_of(matches),
    platform: optional_value(matches, "platform"),
    registry_insecure: flag_of(matches, "insecure-registry"),
    registry_token: optional_value(matches, "registry-token"),
    jobs: jobs_of(matches),
    top: top_of(matches),
    docker_timeout_ms: docker_timeout_of(matches),
  }
}

///|
/// 取开关：没给算 `false`。
fn flag_of(matches : @argparse.Matches, name : String) -> Bool {
  match matches.flags.get(name) {
    Some(value) => value
    None => false
  }
}

///|
/// 取第一个取值，缺省空串。
fn first_value(matches : @argparse.Matches, name : String) -> String {
  match matches.values.get(name) {
    Some(values) => if values.length() > 0 { values[0] } else { "" }
    None => ""
  }
}

///|
/// 取可选参数，没给或给了空串都算没给。
fn optional_value(matches : @argparse.Matches, name : String) -> String? {
  let value = first_value(matches, name)
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
/// 解析 `--layer`：非数字直接报错到 stderr 并按 exit 2 退出。
fn layer_of(matches : @argparse.Matches) -> Int32? {
  match optional_value(matches, "layer") {
    None => None
    Some(text) => Some(non_negative_int_or_exit(text, "--layer"))
  }
}

///|
/// 解析 `--top`：缺省 10；`0` 表示不截断。
fn top_of(matches : @argparse.Matches) -> Int32 {
  match optional_value(matches, "top") {
    None => 10
    Some(text) => non_negative_int_or_exit(text, "--top")
  }
}

///|
/// 解析 `--jobs`：同时在途的层数。
///
/// 0 直接报参数错，不悄悄当 1：给了 0 的人多半以为「不限」，
/// 那正是最该说清楚的地方。上限也钉死——再多也只是把 CDN 的限速队列拉长。
fn jobs_of(matches : @argparse.Matches) -> Int32 {
  let jobs = match optional_value(matches, "jobs") {
    None => return 4
    Some(text) => non_negative_int_or_exit(text, "--jobs")
  }
  if jobs < 1 {
    eprintln(
      "invalid --jobs: expect at least 1 (1 = download layers one at a time)",
    )
    exit_process(@image_ci.exit_config_error)
  }
  if jobs > 16 {
    eprintln("invalid --jobs: at most 16 layers in flight")
    exit_process(@image_ci.exit_config_error)
  }
  jobs
}

///|
/// 解析 `--timeout`：缺省用 `docker_cli` 的默认值（30 秒）。
///
/// 只认真整数秒并且必须 **> 0**：0 及负数在 `docker_cli` 里表示「不设超时」，
/// 而 CLI 上不提供这个选项——不给超时会让半死的 daemon 把进程挂住，
/// 用户看到的是「跑起来没有任何输出」。想要更长就显式给个更大的秒数。
fn docker_timeout_of(matches : @argparse.Matches) -> Int32 {
  let seconds = match optional_value(matches, "timeout") {
    None => return @docker_cli.default_timeout_ms
    Some(text) => non_negative_int_or_exit(text, "--timeout")
  }
  if seconds <= 0 {
    eprintln("invalid --timeout: expect a positive number of seconds")
    exit_process(@image_ci.exit_config_error)
  }
  seconds * 1000
}

///|
/// 解析 `--archive-format`：只认 docker-archive / oci，别的直接报错退出。
fn archive_format_of(
  matches : @argparse.Matches,
) -> @registry_cli.ArchiveFormat {
  let text = first_value(matches, "archive-format")
  if text.is_empty() {
    return @registry_cli.DockerArchive
  }
  match @registry_cli.parse_format(text) {
    Some(format) => format
    None => {
      eprintln(
        "invalid --archive-format: expect docker-archive or oci, got \{text}",
      )
      exit_process(@image_ci.exit_config_error)
      @registry_cli.DockerArchive
    }
  }
}

///|
/// 把命令行的 registry 相关选项摊成一份 `RegistryOptions`。
fn registry_options(options : Options) -> RegistryOptions {
  {
    reference: options.image,
    output: options.output.unwrap_or(""),
    format: options.archive_format,
    platform: options.platform,
    insecure: options.registry_insecure,
    token: options.registry_token,
    jobs: options.jobs,
  }
}

///|
/// `--save`：只取不分析。
///
/// 只对**镜像引用**生效。位置参数本来就是个本地归档时，`--save` 没有任何意义
/// （它就在你手上），这里直接按参数错拒绝——照旧的理由：不落盘还硬跑的唯一
/// 动机是想看网络通不通，而把一个已有的 tar 悄悄写进临时目录是最糟的一种“成功”。
///
/// `-o` 在 `--save` 下就是落盘位置，不和 `--format html -o report.html` 抢：
/// 那条 `-o` 只在分析态生效（`--save` 压根不出报告）。
async fn save_only(options : Options) -> Unit raise CommandError {
  if options.output is None {
    raise CommandError::Registry(
      "--save needs -o/--output: give the file (docker-archive) or directory (oci) to write",
    )
  }
  if is_local_input(options.image) {
    raise CommandError::Image(
      "input is already a local archive, --save has nothing to do: drop --save to analyze \{options.image}, or give an image reference to save",
    )
  }
  let result = save_remote(registry_options(options))
  report_saved(result.0)
}

///|
/// 非负整数，否则报错到 stderr 并按 exit 2 退出。
fn non_negative_int_or_exit(text : String, option : String) -> Int32 {
  match parse_non_negative_int(text) {
    Some(value) => value
    None => {
      eprintln("invalid \{option}: expect a non-negative integer, got \{text}")
      exit_process(@image_ci.exit_config_error)
      0
    }
  }
}

///|
/// 只认十进制非负整数；空串、带符号、带其它字符一律算非法。
fn parse_non_negative_int(text : String) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for unit in text {
    let code = unit.to_int()
    if code < '0'.to_int() || code > '9'.to_int() {
      return None
    }
    value = value * 10 + (code - '0'.to_int())
  }
  Some(value)
}

///|
/// 一次运行里可能出的错；都按 `exit 2` 处理，但信息要能区分。
suberror CommandError {
  Image(String)
  Analysis(String)
  /// 走 docker 后端取归档失败：子进程失败、超时、镜像名不合法等
  Docker(String)
  /// 镜像引用这条路走不通：本地没有这个镜像（`--no-pull` 下没法拉），
  /// 或者这台机器一个 docker 后端都没有。
  ///
  /// 与 `Docker` 分开是因为这是**用户该做的下一步不同**：前者该 `docker pull`，
  /// 后者该装 docker（或者允许出网走 registry）。都塞进一句 `Docker` 时，
  /// 只能靠文案里有没有 `no usable docker backend` 来分辨。
  NoLocalImage(String)
  /// registry 拉取 / `--save` 失败：认证、404、digest 不符、落盘失败等
  Registry(String)
} derive(Eq, Debug)

///|
/// 报错到 stderr。
fn report_error(error : CommandError) -> Unit {
  match error {
    Image(message) => eprintln("image error: \{message}")
    Analysis(message) => eprintln("analysis error: \{message}")
    // `DockerCliError` 的 `Show` 已经带了安装提示，这里只补一句「怎么绕过」
    Docker(message) => eprintln("docker error: \{message}")
    NoLocalImage(message) => eprintln("image error: \{message}")
    Registry(message) => eprintln("registry error: \{message}")
  }
}

///|
/// 位置参数的三种形态。判定只做三档，见 `load_source`。
enum InputKind {
  /// `-`：从 stdin 读
  Stdin
  /// 路径存在（文件或目录）：本地归档 / OCI layout，一步都不碰网络
  LocalPath
  /// 其余：当镜像引用（`nginx:latest`、`docker.cnb.cool/x/y:tag`）
  Reference
} derive(Eq, Debug)

///|
/// 这个位置参数是不是一份**已经存在**的本地输入（stdin 或路径）。
///
/// 只问本地文件系统，不依赖 `docker_cli`：判定不该为了「这像不像镜像名」
/// 去连 daemon。`@fs.path_exists` 在 native 上是 `stat`，够用。
fn is_local_input(image : String) -> Bool {
  match kind_of_input(image) {
    Reference => false
    _ => true
  }
}

///|
/// 三档判定。`-` 是 stdin 的约定写法（`ImageSource::load` 也认这一个），
/// 其余「存在即本地、否则当镜像引用」。
///
/// 必须在 `ImageSource::load` **之前**判：对不存在的路径，load 会一路走到
/// `fopen` 失败，报「cannot read nginx:latest: No such file or directory」——
/// 对打错文件名的人这是人话，对镜像名就纯属误导。
fn kind_of_input(image : String) -> InputKind {
  if image == "-" {
    Stdin
  } else if @fs.path_exists(image) {
    LocalPath
  } else {
    Reference
  }
}

///|
/// 拿到待分析的镜像来源。位置参数自己说它是什么（issue #124）：
///
/// - `-` → stdin
/// - 路径存在 → 本地归档 / OCI layout，完全不碰 docker
/// - 其余 → 镜像引用：先问 docker，一个后端都没有时才自己连 registry（issue #109）
///
/// 「镜像引用」这一档里先 `inspect`（纯本地）：本地有就 `save`，没有就 `pull` 一次
/// 再 `save`——对齐原版 dive（Go），那边没有 `--pull` 开关，`ImageNotFound` 就拉一次。
/// `--no-pull` 把 `pull` 与 registry 直拉一起关掉，`inspect` / `save` 照常。
///
/// 产物统一是 docker-archive tar：`docker save` 与 `registry_cli` 落的是同一形态，
/// 谁拿到就谁往下走，**不会**为了「统一先塞进 daemon」再 `docker load` 一遍。
async fn load_source(
  options : Options,
  env~ : Map[String, String] = @docker_cli.process_env(),
  candidates? : Array[@docker_cli.BackendCandidate],
) -> @image_ci.ImageSource raise CommandError {
  match kind_of_input(options.image) {
    Stdin | LocalPath =>
      @image_ci.ImageSource::load(options.image) catch {
        err => raise CommandError::Image(err.to_string())
      }
    Reference => load_reference(options, env~, candidates?)
  }
}

///|
/// 镜像引用这一档：docker 优先，完全没有后端时才改走 registry。
///
/// 顺序不能对调，也不能「先弄进 daemon 再 save」：`DockerCliSource::save` 走的是
/// `docker save <ref>`，镜像必须已经在 daemon 里——把 registry 直拉到的 tar 再喂进
/// daemon 纯属绕圈。两条路的产物都是 docker-archive tar，这才是「零 daemon 分析」
/// 还能成立的前提（issue #124 第 6 节）。
async fn load_reference(
  options : Options,
  env~ : Map[String, String],
  candidates? : Array[@docker_cli.BackendCandidate],
) -> @image_ci.ImageSource raise CommandError {
  // `save` 期间只说「开始」不说「进度」，用户手上唯一的线索就是这行耗时。
  // 装上钩子之后，收尾时会补一句「多久、最长静默多久、多少字节」——
  // 这是判断该不该调 `--timeout` 的唯一依据（issue #94）。
  if options.verbose {
    @docker_cli.save_progress_hook.val = Some(fn(
      elapsed_ms,
      peak_idle_ms,
      bytes,
    ) {
      eprintln(
        "[docker] saved \{bytes} bytes in \{elapsed_ms}ms " +
        "(longest silence \{peak_idle_ms}ms)",
      )
    })
  }
  let (archive, resolved) = @docker_cli.fetch_archive_verbose(
    options.image,
    env~,
    timeout_ms=options.docker_timeout_ms,
    candidates?,
    pull_if_missing=!options.no_pull,
    on_stage=fn(stage) { describe_stage(options, stage) },
  ) catch {
    err => {
      // 这台机器一条能走的路都没有：位置参数既然是镜像名，就自己连 registry
      // （issue #109）。`--no-pull` 在场时不兜——那个开关的意思是「不许上网」。
      if !options.no_pull && @docker_cli.no_backend_at_all(err) {
        return fallback_to_registry(options, err)
      }
      // 有 docker 但取不到（含 `--no-pull` 下本地没有、名字非法）：**不回退**。
      // 拿一次注定失败的 registry 拉取盖住真正的错，是这里最该防的回归。
      raise classify_docker_error(options, err)
    }
  }
  // 探测记录走 stderr，别混进报告：报告还可能被 `-o` / 管道消费
  if options.verbose {
    let described = @docker_cli.describe_backends(resolved.probed)
    if !described.is_empty() {
      eprintln(described)
    }
  }
  // 解压 + 叠树是纯本地计算，但大镜像上并不快（见 `layer_tree` 的 gzip 注释）。
  // 这里点一句，免得「取完归档到出报告之间」被当成又卡住了。
  if options.verbose {
    eprintln("[docker] parsing archive (decompress + stack layers)...")
  }
  // name 用来标注报告 / 注解：告诉读的人「这不是本地 tar，是取回来的镜像」
  @image_ci.ImageSource::from_tar_bytes(
    archive,
    name="\{options.image} (from-image)",
  ) catch {
    err => raise CommandError::Image(err.to_string())
  }
}

///|
/// 把 docker 侧的错误分成两条不同的「下一步」。
///
/// `--no-pull` 下的两种失败要分开报：
/// - **本地没这个镜像**（`ImageNotFound`）→ `NoLocalImage`：用户该 `docker pull` 一次，
///   或者去掉 `--no-pull` 让它自己拉；
/// - **这台机器没有 docker**（`NoBackend` 且一个候选都没通过）→ `Docker`：
///   用户该装 docker，或者允许出网走 registry。
///
/// 合并成一句 `Docker` 时，只能靠文案里有没有 `no usable docker backend` 来分辨
/// （`from_image_wbtest.mbt` 之前正是这么断言）。类型分开之后，
/// 文案可以只管说人话，判断留给调用方。
fn classify_docker_error(
  options : Options,
  err : @docker_cli.DockerCliError,
) -> CommandError {
  match err {
    @docker_cli.ImageNotFound(reference) =>
      if options.no_pull {
        NoLocalImage(
          "no such image locally: \{reference}, and --no-pull forbids pulling it",
        )
      } else {
        Docker(err.to_string())
      }
    _ => Docker(err.to_string())
  }
}

///|
/// 镜像引用这一档买不到 docker 时的兜底：改走 registry 直拉。
///
/// 触发条件只有「这台机器上没有一条能走的路」（见 `no_backend_at_all`），
/// 而且 `--no-pull` 在场就不兜——那个开关的意思是「不许上网」，
/// 而直连 registry 是最彻底的上网。两种情况下错误原样抛出去，
/// 由 `Docker(message)` 带着安装提示说话。
///
/// 探测记录照旧走 stderr：回退之后，「为什么没用 docker」仍然是排查时
/// 第一个要看的东西，而报告还可能被 `-o` / 管道消费，不能混进去。
///
/// token 按位置参数的原样引用去 `$DIVE_REGISTRY_TOKEN` 取（见 `registry_cli`）：
/// 被回退的多半是 CNB 这类带 `docker.cnb.cool/` 前缀的镜像名，
/// 而那个环境里正好是这个变量装着凭据。
async fn fallback_to_registry(
  options : Options,
  err : @docker_cli.DockerCliError,
) -> @image_ci.ImageSource raise CommandError {
  let probed = match err {
    @docker_cli.NoBackend(_, probed) => probed
    _ => ""
  }
  if options.verbose && !probed.is_empty() {
    eprintln(probed)
  }
  eprintln(
    "no docker backend here, pulling \{options.image} straight from its registry",
  )
  load_from_registry(options)
}

///|
/// 取归档过程中的阶段回调：镜像引用那一档**边做边打**，而不是等结束再补一份报告。
///
/// 之前这些行是在 `fetch_archive_verbose` **返回之后**统一打印的，
/// 于是「will pull / timeout 30s」出现在「已经拉完」之后，读起来像倒放；
/// 更糟的是取归档阶段一旦没输出，用户会以为进程卡死（issue #42 的现场）。
fn describe_stage(options : Options, stage : @docker_cli.FetchStage) -> Unit {
  if !options.verbose {
    return
  }
  match stage {
    Resolved(backend) => {
      eprintln("[docker] using \{@docker_cli.ImageBackend::to_string(backend)}")
      if options.no_pull {
        eprintln(
          "[docker] --no-pull: never touch the network (no pull, no registry)",
        )
      } else {
        eprintln("[docker] will pull the image if it is missing locally")
      }
      eprintln(
        "[docker] timeout: \{options.docker_timeout_ms / 1000}s of silence per call",
      )
      eprintln(
        "[docker] a backend that cannot serve the image hands off to the next candidate",
      )
    }
    Trying(backend) =>
      eprintln(
        "[docker] trying \{@docker_cli.ImageBackend::to_string(backend)}...",
      )
    // 开始新的等待：打一句带时刻的，结束再由下一句（或最终结果）收尾。
    // 用户能据此判断「卡在哪一步、已经卡了多久」——这正是 issue #94 里
    // 一句 `was cancelled` 提供不了的信息。
    Pulling(reference) =>
      eprintln("[docker] no local image, pulling \{reference}...")
    Saving(reference) => eprintln("[docker] saving \{reference}...")
  }
}

///|
/// 分析阶段的进度钩子（`--verbose` 才开）。
///
/// 下载完到出报告之间原本一句输出都没有，用户看到的就是「进度条停在 100%」
/// （issue #122）。这里只做「打一行到 stderr」：报告还可能被 `-o` / 管道消费，
/// 进度绝不能混进 stdout。
fn analysis_progress(options : Options) -> ((Int32, Int32) -> Unit)? {
  if !options.verbose {
    return None
  }
  Some(fn(index, total) { eprintln("[analysis] layer \{index + 1}/\{total}") })
}

///|
/// 跑一遍完整链路，返回退出码。
async fn run(
  options : Options,
  source : @image_ci.ImageSource,
) -> Int32 raise CommandError {
  if source.layers.is_empty() {
    raise CommandError::Image("image has no layers")
  }
  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = []
  for layer in source.layers {
    let raw = layer.raw_bytes() catch {
      err => raise CommandError::Image(err.to_string())
    }
    layers.push(raw)
  }
  if options.efficiency {
    return run_efficiency_view(options, layers)
  }
  if options.layer is Some(_) || options.path is Some(_) || options.aggregate {
    return run_layer_view(options, layers)
  }
  let on_layer = analysis_progress(options)
  let analysis = @image_analysis.analyze_layers(tree, layers, on_layer~) catch {
    err => raise CommandError::Analysis(err.to_string())
  }
  if options.verbose {
    eprintln("[analysis] building the report (\{tree.size()} paths)")
  }
  let report = @image_analysis.build_report(analysis, tree)
  let ruleset = load_rules(options)
  let result = ruleset.check(report, tree, image=options.image)
  match options.format {
    "json" => println(result.to_json_string())
    "html" =>
      write_report_output(options, @image_analysis.report_to_html(report))
    "annotations" => println(result.to_annotations())
    _ => {
      println(@image_analysis.render_text_report(report))
      println(result.to_text())
    }
  }
  @image_ci.exit_code_of(result)
}

///|
/// 报告输出：给了 `-o` 就写文件，否则打到 stdout。
///
/// HTML 是给人双击看的，写文件才是主用法；不给 `-o` 时退化成 stdout，
/// 便于 `dive img --format html > report.html` 这类管道。
/// 写文件失败按「镜像读不出来」以外的运行错误处理，退 exit 2。
fn write_report_output(options : Options, text : String) -> Unit {
  let path = match options.output {
    Some(path) => path
    None => {
      println(text)
      return
    }
  }
  @fs.write_string_to_file(path, text) catch {
    @fs.IOError(message) => {
      eprintln("cannot write \{path}: \{message}")
      exit_process(@image_ci.exit_config_error)
    }
  }
  println("report written to \{path}")
}

///|
/// `--layer` / `--path` 分支：只出「某一层的文件树 + 该层 diff」，不做门禁。
///
/// 没有 TUI：每次调用渲染一层快照，交互由 shell 的历史 / 循环补。
///
/// `--aggregate` 换的是**比较区间**而不是数据源（issue #69）：树仍是第 n 层的，
/// 但 diff 换成「第 0 层之前到现在这一整段的累积」，与 TUI 的 `Ctrl+A` 同义。
/// `removed` 不在树上，所以单独列一段——它是「这段区间少了什么」的唯一出口。
async fn run_layer_view(
  options : Options,
  layers : Array[BytesView],
) -> Int32 raise CommandError {
  let views = @layer_tree.browse_layers(layers) catch {
    err => raise CommandError::Analysis(err.to_string())
  }
  let wanted = match options.layer {
    Some(layer) => layer
    // 只给 `--path` 时默认看最后一层
    None => views.length() - 1
  }
  if wanted < 0 || wanted >= views.length() {
    raise CommandError::Analysis(
      "layer \{wanted} is out of range: image has \{views.length()} layer(s) (0..\{views.length() - 1})",
    )
  }
  let view = views[wanted]
  match options.format {
    "json" =>
      println(
        layer_view_to_json(view, compare_diff(view, options), options).stringify(
          indent=2,
        ),
      )
    _ => println(render_layer_view(view, options, views.length()))
  }
  @image_ci.exit_ok
}

///|
/// 逐层视图的文本：`run_layer_view` 与测试共用同一段渲染，
/// 断言不用去截 `println` 的 stdout（那是真终端/子进程的事）。
fn render_layer_view(
  view : @layer_tree.LayerView,
  options : Options,
  total_layers : Int32,
) -> String {
  let subtree = match options.path {
    Some(path) => view.subtree(path)
    None => view.tree
  }
  let diff = compare_diff(view, options)
  let builder = StringBuilder()
  builder.write_string(
    "layer \{view.layer} of \{total_layers} (\{subtree.size()} path(s))\n",
  )
  builder.write_string("compare: \{compare_name(options)}\n")
  // `render_diff` 给三组路径的全量清单；`Diff` 自己的 `Show` 只是计数摘要
  builder.write_string(@layer_tree.render_diff(diff))
  if !diff.removed.is_empty() {
    // 被删的路径不在树上，没有行可以给它标红——这里再点一句它们不在树上
    builder.write_string("removed (not in the tree):\n")
    for path in diff.removed {
      builder.write_string("  \{path}\n")
    }
  }
  builder.write_string(@layer_tree.render_tree(subtree))
  builder.to_string()
}

///|
/// 当前档位下给视图用的 diff：默认是逐层 diff，`--aggregate` 换成累积的。
fn compare_diff(
  view : @layer_tree.LayerView,
  options : Options,
) -> @layer_tree.Diff {
  if options.aggregate {
    view.aggregate
  } else {
    view.diff
  }
}

///|
/// 档位的机器可读名：`layer` / `aggregate`。
fn compare_name(options : Options) -> String {
  if options.aggregate {
    "aggregate"
  } else {
    "layer"
  }
}

///|
/// 逐层视图的 JSON：给脚本消费，字段与文本视图一一对应。
///
/// `schemaVersion` 不动：本轮只是给 `compare` 与 `aggregateBytes` 各加一个字段，
/// 既有字段一个都没改（默认档位下数值与从前完全一致）。
fn layer_view_to_json(
  view : @layer_tree.LayerView,
  diff : @layer_tree.Diff,
  options : Options,
) -> Json {
  Json::object({
    "schemaVersion": Json(1),
    "layer": Json(view.layer),
    "tree": Json(@layer_tree.render_tree(view.tree)),
    "path": Json(
      match options.path {
        Some(path) => Json(path)
        None => Json(null)
      },
    ),
    "compare": Json(compare_name(options)),
    "aggregateBytes": Json(view.aggregate_size_delta(view.aggregate.base)),
    "diff": Json::object({
      "base": Json(diff.base),
      "added": Json(diff.added.map(fn(path) { Json(path) })),
      "modified": Json(diff.modified.map(fn(path) { Json(path) })),
      "removed": Json(diff.removed.map(fn(path) { Json(path) })),
    }),
  })
}

///|
/// `--efficiency` 分支：只出「按多写空间排的路径表」，不做门禁。
///
/// 数字全部来自 `EfficiencyReport.paths`（即 efficiency score 的同一批原料），
/// 这里只负责渲染与截断。与 `--layer` 一样返回 `exit_ok`：
/// 这是一张观察用的表，不是判定。
async fn run_efficiency_view(
  options : Options,
  layers : Array[BytesView],
) -> Int32 raise CommandError {
  let tree = @layer_tree.FileTree::new()
  let on_layer = analysis_progress(options)
  let analysis = @image_analysis.analyze_layers(tree, layers, on_layer~) catch {
    err => raise CommandError::Analysis(err.to_string())
  }
  if options.verbose {
    eprintln("[analysis] building the report (\{tree.size()} paths)")
  }
  let report = analysis.efficiency()
  let view = @image_analysis.EfficiencyViewOptions::new(
    path=options.path,
    // `--top 0` 是「全都要」，内部用负数表示不截断
    top=if options.top == 0 { -1 } else { options.top },
  )
  match options.format {
    "json" =>
      println(@image_analysis.efficiency_view_to_json_string(report, view))
    _ => println(@image_analysis.render_efficiency_view(report, view))
  }
  @image_ci.exit_ok
}

///|
/// 读规则文件。没给 `--rules` 时只出分析报告，不做门禁判定。
///
/// 规则读不到 / 解析失败都按「规则非法」处理：打印人话 + JSON 兜底结果 + CI 注解，
/// 然后 exit 2——与「规则未通过」的 exit 1 分开，看日志的人一眼能分。
fn load_rules(options : Options) -> @image_ci.Ruleset noraise {
  let path = match options.rules {
    Some(path) => path
    None => return @image_ci.Ruleset::empty("<no rules>")
  }
  let text = @fs.read_file_to_string(path) catch {
    @fs.IOError(message) => {
      eprintln("cannot read rules \{path}: \{message}")
      exit_process(@image_ci.exit_config_error)
      ""
    }
  }
  let ruleset = @image_ci.Ruleset::parse(text, source=path) catch {
    err => {
      eprintln(err.to_string())
      println(@image_ci.config_error_to_json(err, path).stringify(indent=2))
      println(@image_ci.config_error_annotation(err, path))
      exit_process(@image_ci.exit_config_error)
      @image_ci.Ruleset::empty(path)
    }
  }
  ruleset
}
