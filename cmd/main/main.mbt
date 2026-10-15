///|
/// `dive` 的只读分析入口：`dive <image> [--rules rules.json] [--layer N] [--path P] [--efficiency]`。
///
/// 链路是 P1/P2 → P3 → P4 的串接：
///
/// 1. 读本地镜像产物（docker save / OCI layout / 单层 tar / stdin）
/// 2. 逐层解压后喂给 `layer_tree` 叠树
/// 3. `image_analysis` 出体积报告
/// 4. `image_ci` 按规则判定，输出人类可读 / JSON / CI 注解
///
/// `--pull` 只跟 `--from-image` 一起用：本地没有这个镜像时先去 daemon 拉一次，
/// 默认（不给 `--pull`）绝不发起网络请求，`docker save` 找不到就是找不到。
///
/// `--layer` / `--path` / `--efficiency` 是 dive 交互界面的只读替身：没有 TUI，
/// 但能逐层看文件树、按目录下钻、按「多写了几份」看哪条路径拖了效率。
/// 给了 `--layer` 或 `--efficiency` 就不做门禁判定，只打印对应的那张表。
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
  // `--from-image` 要先连 daemon / 起子进程取归档，这一步是 async；
  // 其余（读文件、分析）都是同步的，取到字节后走进既有链路。
  let source = load_source(options) catch {
    err => {
      report_error(err)
      exit_process(@image_ci.exit_config_error)
      return
    }
  }
  match run(options, source) {
    Ok(code) => exit_process(code)
    Err(error) => {
      report_error(error)
      exit_process(@image_ci.exit_config_error)
    }
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
    ],
    flags=[
      @argparse.FlagArg(
        "efficiency",
        about="show per-path efficiency (cumulative - min), sorted desc, instead of the gate",
      ),
      @argparse.FlagArg(
        "from-image",
        about="treat the positional as an image reference (docker/podman/nerdctl or docker socket)",
      ),
      @argparse.FlagArg(
        "pull",
        about="pull the image when it is missing locally (with --from-image)",
      ),
      @argparse.FlagArg(
        "verbose",
        about="print the docker backend probing log to stderr (with --from-image)",
      ),
    ],
    positionals=[
      @argparse.PositionArg(
        "image",
        about="docker save tar, OCI layout directory, - for stdin, or an image reference with --from-image",
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
  /// 把位置参数当镜像名，走 `docker_cli` 取归档
  from_image : Bool
  /// `--from-image` 时本地没有就先去 `pull`（默认只认本地）
  pull : Bool
  /// 打 `docker_cli` 的后端探测记录
  verbose : Bool
  top : Int32
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
    from_image: flag_of(matches, "from-image"),
    pull: flag_of(matches, "pull"),
    verbose: flag_of(matches, "verbose"),
    top: top_of(matches),
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
  /// `--from-image` 取归档失败：探测不到后端、子进程失败、镜像名不合法等
  Docker(String)
} derive(Eq, Debug)

///|
/// 报错到 stderr。
fn report_error(error : CommandError) -> Unit {
  match error {
    Image(message) => eprintln("image error: \{message}")
    Analysis(message) => eprintln("analysis error: \{message}")
    // `DockerCliError` 的 `Show` 已经带了安装提示，这里只补一句「怎么绕过」
    Docker(message) => eprintln("docker error: \{message}")
  }
}

///|
/// 拿到待分析的镜像来源。
///
/// 两条路：
/// - 默认：把位置参数当文件 / 目录 / `-`，走 `ImageSource::load`，完全不碰 docker
/// - `--from-image`：把位置参数当镜像引用，走 `docker_cli` 取 docker-archive 字节，
///   再喂给既有的 `ImageSource::from_tar_bytes`——**不新开分析链路**
///
/// 显式开关优先：不给 `--from-image` 就绝不连 daemon，
/// 避免「给个文件却去连 docker」这种意外行为；不给 `--pull` 就绝不发起拉取
/// （`--pull` 单独给也没用，必须与 `--from-image` 同时在场）。
async fn load_source(
  options : Options,
  env~ : Map[String, String] = @docker_cli.process_env(),
  candidates? : Array[@docker_cli.BackendCandidate],
) -> @image_ci.ImageSource raise CommandError {
  if !options.from_image {
    return @image_ci.ImageSource::load(options.image) catch {
      err => raise CommandError::Image(err.to_string())
    }
  }
  let (archive, resolved) = @docker_cli.fetch_archive_verbose(
    options.image,
    env~,
    candidates?,
    pull_if_missing=options.pull && options.from_image,
  ) catch {
    // NoBackend / ExecutableNotFound / InvalidReference / Backend 都归到 Docker：
    // `Show` 已经把这些转成人话（含安装提示与子进程 stderr）
    err => raise CommandError::Docker(err.to_string())
  }
  // 探测记录走 stderr，别混进报告：报告还可能被 `-o` / 管道消费
  if options.verbose {
    eprintln(
      "[docker] using \{@docker_cli.ImageBackend::to_string(resolved.backend)}",
    )
    if options.pull {
      eprintln("[docker] --pull: will fetch the image if it is missing locally")
    }
    let described = @docker_cli.describe_backends(resolved.probed)
    if !described.is_empty() {
      eprintln(described)
    }
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
/// 跑一遍完整链路，返回退出码。
fn run(
  options : Options,
  source : @image_ci.ImageSource,
) -> Result[Int32, CommandError] noraise {
  if source.layers.is_empty() {
    return Err(CommandError::Image("image has no layers"))
  }
  let tree = @layer_tree.FileTree::new()
  let layers : Array[BytesView] = []
  for layer in source.layers {
    let raw = layer.raw_bytes() catch {
      err => return Err(CommandError::Image(err.to_string()))
    }
    layers.push(raw)
  }
  if options.efficiency {
    return run_efficiency_view(options, layers)
  }
  if options.layer is Some(_) || options.path is Some(_) {
    return run_layer_view(options, layers)
  }
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    err => return Err(CommandError::Analysis(err.to_string()))
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
  Ok(@image_ci.exit_code_of(result))
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
fn run_layer_view(
  options : Options,
  layers : Array[BytesView],
) -> Result[Int32, CommandError] noraise {
  let views = @layer_tree.browse_layers(layers) catch {
    err => return Err(CommandError::Analysis(err.to_string()))
  }
  let wanted = match options.layer {
    Some(layer) => layer
    // 只给 `--path` 时默认看最后一层
    None => views.length() - 1
  }
  if wanted < 0 || wanted >= views.length() {
    return Err(
      CommandError::Analysis(
        "layer \{wanted} is out of range: image has \{views.length()} layer(s) (0..\{views.length() - 1})",
      ),
    )
  }
  let view = views[wanted]
  let subtree = match options.path {
    Some(path) => view.subtree(path)
    None => view.tree
  }
  match options.format {
    "json" => println(layer_view_to_json(view, options).stringify(indent=2))
    _ => {
      println(
        "layer \{view.layer} of \{views.length()} (\{subtree.size()} path(s))",
      )
      println("diff: \{view.diff}")
      println(@layer_tree.render_tree(subtree))
    }
  }
  Ok(@image_ci.exit_ok)
}

///|
/// 逐层视图的 JSON：给脚本消费，字段与文本视图一一对应。
fn layer_view_to_json(view : @layer_tree.LayerView, options : Options) -> Json {
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
    "diff": Json::object({
      "added": Json(view.diff.added.map(fn(path) { Json(path) })),
      "modified": Json(view.diff.modified.map(fn(path) { Json(path) })),
      "removed": Json(view.diff.removed.map(fn(path) { Json(path) })),
    }),
  })
}

///|
/// `--efficiency` 分支：只出「按多写空间排的路径表」，不做门禁。
///
/// 数字全部来自 `EfficiencyReport.paths`（即 efficiency score 的同一批原料），
/// 这里只负责渲染与截断。与 `--layer` 一样返回 `exit_ok`：
/// 这是一张观察用的表，不是判定。
fn run_efficiency_view(
  options : Options,
  layers : Array[BytesView],
) -> Result[Int32, CommandError] noraise {
  let tree = @layer_tree.FileTree::new()
  let analysis = @image_analysis.analyze_layers(tree, layers) catch {
    err => return Err(CommandError::Analysis(err.to_string()))
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
  Ok(@image_ci.exit_ok)
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
