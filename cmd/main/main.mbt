///|
/// `dive` 的只读分析入口：`dive <image.tar> --rules rules.json`。
///
/// 链路是 P1/P2 → P3 → P4 的串接：
///
/// 1. 读本地镜像产物（docker save / OCI layout / 单层 tar / stdin）
/// 2. 逐层解压后喂给 `layer_tree` 叠树
/// 3. `dive_analysis` 出体积报告
/// 4. `image_ci` 按规则判定，输出人类可读 / JSON / CI 注解
///
/// 退出码由 `image_ci` 定义：`0` 全过、`1` 有规则未通过、
/// `2` 规则非法或镜像读不出来。wasm 下拿不到退出码，详见 `exit.mbt`。
fn main {
  let matches = cli().parse() catch {
    // argparse 的报错里已附用法，直接打出来，按「入参不对」退出
    err => {
      eprintln(err.to_string())
      exit_process(@image_ci.exit_config_error)
      return
    }
  }
  let options = Options::from_matches(matches)
  match run(options) {
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
        about="output format: text, json or annotations",
        default_values=["text"],
      ),
    ],
    positionals=[
      @argparse.PositionArg(
        "image",
        about="docker save tar, OCI layout directory, or - for stdin",
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
/// 一次运行里可能出的错；两类都按 `exit 2` 处理，但信息要能区分。
enum CommandError {
  Image(String)
  Analysis(String)
} derive(Eq, Debug)

///|
/// 报错到 stderr。
fn report_error(error : CommandError) -> Unit {
  match error {
    Image(message) => eprintln("image error: \{message}")
    Analysis(message) => eprintln("analysis error: \{message}")
  }
}

///|
/// 跑一遍完整链路，返回退出码。
fn run(options : Options) -> Result[Int32, CommandError] noraise {
  let source = @image_ci.ImageSource::load(options.image) catch {
    err => return Err(CommandError::Image(err.to_string()))
  }
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
  let analysis = @dive_analysis.analyze_layers(tree, layers) catch {
    err => return Err(CommandError::Analysis(err.to_string()))
  }
  let report = @dive_analysis.build_report(analysis, tree)
  let ruleset = load_rules(options)
  let result = ruleset.check(report, tree, image=options.image)
  match options.format {
    "json" => println(result.to_json_string())
    "annotations" => println(result.to_annotations())
    _ => {
      println(@dive_analysis.render_text_report(report))
      println(result.to_text())
    }
  }
  Ok(@image_ci.exit_code_of(result))
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
