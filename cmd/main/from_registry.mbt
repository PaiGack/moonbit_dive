///|
/// 远端镜像 / `--save` 分支的选项。
///
/// 两个动作共用一组参数：`--save` 只落盘，镜像引用那条路落盘后继续分析。
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
/// 远端 registry → 内存里的镜像来源：**拉下来的 blob 原样落地，不打包**。
///
/// 位置参数是镜像引用、而这台机器又没有 docker 时走这条路（issue #109）；
/// `--save` 直接调 `save_remote`，不经过这里。
///
/// 以前这里先攒一张 docker-archive 再 `ImageSource::load` 读回来。那样做的
/// 唯一好处是「格式识别只有一份」，代价却是每次分析都要
/// 「逐层解压 → 套 tar → 再按 tar 偏移把层找回来 → 再解压一遍」——
/// 700MB 的镜像要写 2 GiB 的中间文件，而分析链路从来只用得到解压后的字节
/// （issue #133）。现在层就是下载下来的压缩 blob，`ImageSource::raw_bytes`
/// 照 media type 解压，与读 OCI layout 目录走的是同一条路。
///
/// 临时目录无论成败都要收掉：失败时留着只会攒垃圾。
async fn load_from_registry(
  options : Options,
) -> @image_ci.ImageSource raise CommandError {
  let registry_options = registry_options(options)
  let (image, directory) = stream_remote(registry_options)
  // 先把镜像读进内存，**之后**才轮到删临时目录：反过来的话，删掉的正是
  // 紧接着要 `fopen` 的那几个 blob（issue #122 的现场）。
  // 所以是 `defer` 而不是 `errdefer`：成败都得收
  defer cleanup_streamed(image, directory)
  registry_source(options, image)
}

///|
/// 把流式拉到的镜像变成 `ImageSource`：config 解析成镜像元信息，层按路径交出去。
///
/// 读不出来时要把「哪一份产物读不出来」带上：`ImageSource` 的错只提路径，
/// 而这个路径在临时目录里，用户根本没机会去看它（issue #122）。
fn registry_source(
  options : Options,
  image : @registry_cli.StreamedImage,
) -> @image_ci.ImageSource raise CommandError {
  if options.verbose {
    eprintln(
      "[registry] reading \{image.layers.length()} layer blobs from \{image.staging}...",
    )
  }
  let layers : Array[@image_ci.BlobLayer] = []
  for layer in image.layers {
    layers.push({
      media_type: layer.media_type,
      digest: layer.digest,
      path: layer.path,
      size: layer.size,
      diff_id: "",
    })
  }
  // 读**现在**就读，不留路径：临时目录在这次调用之后就要收掉（`cleanup_streamed`），
  // 而 `ImageSource` 要活到分析结束。只留路径的话，收目录等于把层删了，
  // 报出来只有一句 `No such file or directory`——看不出是谁收了它（issue #138）
  @image_ci.ImageSource::from_oci_files(
    "\{options.image} (from-registry)",
    image.config_json,
    layers,
  ) catch {
    err =>
      raise CommandError::Image(
        "pulled \{options.image} from its registry but cannot read it back: \{err.to_string()}; this looks like a bug in dive pull",
      )
  }
}

///|
/// 拉一次远端镜像，层落在临时目录里，返回产物与那个目录。
///
/// 不给 `--output`（分析这条路上没有产物）时落点是 `dive-registry-*`；
/// 给了 `--output` 的用户是想要一份归档，那条路仍然走 `save_remote`。
async fn stream_remote(
  options : RegistryOptions,
) -> (@registry_cli.StreamedImage, String) raise CommandError {
  // 进度**默认就显示**：拉一个 700MB 的镜像时一声不吭，用户只会以为程序死了
  // （issue #97）。`--verbose` 管的是后端探测之类的调试信息，
  // 不该同时决定「看不看得到进度」。
  let reporter = @registry_cli.PullReporter::new()
  let tick : () -> Unit = fn() { reporter.flush() }
  let request = @registry_cli.StreamRequest::new(
    reference=options.reference,
    platform=options.platform,
    insecure=options.insecure,
    token=options.token,
    on_progress=Some(reporter.handle()),
    on_tick=Some(tick),
    jobs=options.jobs,
  )
  let image = @registry_cli.stream_image(request) catch {
    err => {
      // 报错前把半行进度收个尾，否则错误信息会接在进度条后面
      reporter.finish(failed=true)
      raise CommandError::Registry(err.to_string())
    }
  }
  reporter.finish(failed=false)
  (image, image.staging)
}

///|
/// 收掉这次流式拉取建的临时目录。
///
/// 产物归调用方时（给了 `--output`）一个字节都不碰——那条路走的是
/// `save_remote`，目录里本来也没有我们造的东西。
async fn cleanup_streamed(
  image : @registry_cli.StreamedImage,
  directory : String,
) -> Unit noraise {
  if image.staging != directory {
    return
  }
  @registry_cli.discard_streamed(image)
}

///|
/// 拉一次远端镜像并落盘，返回落盘结果。
///
/// 落盘位置在**临时目录**里：分析链路只认「路径」这个入口（`ImageSource::load`），
/// 直接塞字节会绕过既有的格式识别（docker-archive / OCI layout / 单层 tar 三种），
/// 那正是我们最不该分叉的一段逻辑。
///
/// 临时产物**不在这里收**：装完之后 `ImageSource` 只记偏移，层要等到 `main`
/// 里逐层 `raw_bytes` 才真去读。在这里删，删的就是那份还没人读过的归档
/// （issue #133）。`/tmp` 会替我们收尾。
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
/// 打印一行结果摘要（`--save` 的主输出）。
fn report_saved(result : @registry_cli.SaveResult) -> Unit {
  println(
    "saved \{result.path} (\{result.format}, \{result.bytes} bytes, \{result.layers} layers, \{result.platform})",
  )
}
