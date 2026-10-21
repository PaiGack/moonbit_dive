///|
/// `--from-registry` / `--save` 分支的选项。
///
/// 两个动作共用一组参数：`--save` 只落盘、`--from-registry` 落盘后继续分析。
/// 合成一个结构是因为它们面对的是同一件事——「远端 registry 里的镜像」，
/// 拆成两套参数只会让两个分支的写法慢慢漂移。
priv struct RegistryOptions {
  /// 镜像引用（位置参数）
  reference : String
  /// `--output`：落盘位置
  output : String
  format : @registry_cli.ArchiveFormat
  platform : String?
  insecure : Bool
  token : String?
  /// 同时在途的层数（1 = 逐层串行）
  jobs : Int32
}

///|
/// 远端 registry → 内存里的镜像来源：落盘到临时目录，再走既有 `ImageSource::load`。
///
/// 落成文件再读回来是**故意的**：三种输入格式（docker-archive / OCI layout /
/// 单层 tar）的识别逻辑只有一份，不该为「内存里的镜像」再写一套。
/// 临时产物无论成败都要收掉：失败时留着只会攒垃圾。
async fn load_from_registry(
  options : Options,
) -> @image_ci.ImageSource raise CommandError {
  let registry_options = registry_options(options)
  let (result, directory) = save_remote(registry_options)
  // 临时目录要整份收掉。只删 `result.path` 会漏掉流式落盘的 `dive-blobs-*`
  // 之类同伴目录；而如果删的是 `result.path` 之外的目录，用户看到的就是
  // 「writing .../image.tar」之后再来一句「No such file or directory」（issue #122）
  errdefer cleanup_remote(registry_options, directory)
  if options.verbose {
    eprintln("[registry] parsing \{result.path}...")
  }
  let source = @image_ci.ImageSource::load(result.path) catch {
    err => raise CommandError::Image(err.to_string())
  }
  cleanup_remote(registry_options, directory)
  source
}

///|
/// 拉一次远端镜像并落盘，返回落盘结果。
///
/// 落盘位置在**临时目录**里：分析链路只认「路径」这个入口（`ImageSource::load`），
/// 直接塞字节会绕过既有的格式识别（docker-archive / OCI layout / 单层 tar 三种），
/// 那正是我们最不该分叉的一段逻辑。分析完立刻删掉，不污染用户目录。
async fn save_remote(
  options : RegistryOptions,
) -> (@registry_cli.SaveResult, String) raise CommandError {
  let directory = @async_fs.tmpdir(prefix="dive-registry-") catch {
    err =>
      raise CommandError::Registry("cannot create a temp directory: \{err}")
  }
  let output = if options.output.is_empty() {
    match options.format {
      @registry_cli.DockerArchive => "\{directory}/image.tar"
      @registry_cli.OciLayout => "\{directory}/layout"
    }
  } else {
    options.output
  }
  // 进度**默认就显示**：拉一个 700MB 的镜像时一声不吭，用户只会以为程序死了
  // （issue #97）。`--verbose` 管的是后端探测之类的调试信息，
  // 不该同时决定「看不看得到进度」。
  let reporter = @registry_cli.PullReporter::new()
  // 回调是同步的、写终端也是同步的（走 C 的 write(2)），所以这里直接刷
  let tick : () -> Unit = fn() { reporter.flush() }
  let request = @registry_cli.SaveRequest::new(
    reference=options.reference,
    output~,
    format=options.format,
    platform=options.platform,
    insecure=options.insecure,
    token=options.token,
    on_progress=Some(reporter.handle()),
    on_tick=Some(tick),
    jobs=options.jobs,
  )
  let result = @registry_cli.save_image(request) catch {
    err => {
      // 报错前把半行进度收个尾，否则错误信息会接在进度条后面
      reporter.finish(failed=true)
      raise CommandError::Registry(err.to_string())
    }
  }
  reporter.finish(failed=false)
  (result, directory)
}

///|
/// 分析完把临时目录删掉；用户显式给了 `--output` 就只删临时目录，
/// 落盘产物留给他（那正是他要的东西）。
async fn cleanup_remote(
  options : RegistryOptions,
  directory : String,
) -> Unit noraise {
  if !options.output.is_empty() {
    // 用户自己指了位置，落盘产物归他；临时目录仍然是我们的，照样收掉
    rmdir_quietly(directory)
    return
  }
  // `dive-registry-*` 是这次拉取的落脚点，里面的东西全是我们造的：
  // 整棵删掉比「按 format 猜那个 `result.path` 是文件还是目录」更不容易漏
  rmdir_quietly(directory)
}

///|
/// 递归删目录，删不掉就算了：这里多半已经在报错的路上。
async fn rmdir_quietly(directory : String) -> Unit noraise {
  try @async_fs.rmdir(directory, recursive=true) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// 打印一行结果摘要（`--save` 的主输出）。
fn report_saved(result : @registry_cli.SaveResult) -> Unit {
  println(
    "saved \{result.path} (\{result.format}, \{result.bytes} bytes, \{result.layers} layers, \{result.platform})",
  )
}
