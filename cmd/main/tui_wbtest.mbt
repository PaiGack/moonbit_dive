///|
/// 界面出口的接线：命令行开关 → 起始态（issue #128 第二节）。
///
/// 这里只验「映射对不对」，真开界面要终端、要人在前面按 `q`，不进单测。
/// 每个开关都得有个落点：`--layer` 起始层、`--aggregate` 起始档位、
/// `--path` 光标落点、`--efficiency` 详情面板聚焦。
async test "cli flags map onto the browser start config" {
  let options = parse_options([
    "demo.tar", "--layer", "1", "--aggregate", "--path", "/app", "--efficiency",
  ])
  let notices : Array[String] = []
  let start = start_config_of(options, 3, notices)
  assert_eq(start.layer, 1)
  assert_eq(start.compare_mode, @tui.CompareMode::Aggregate)
  assert_eq(start.path, Some("/app"))
  assert_eq(start.focus, @tui.Focus::Detail)
  assert_true(notices.is_empty())
}

///|
/// 不给 `--layer` 就看最后一层——与文本出口的缺省同口径。
/// 给了但越界不拦路：夹回最后一层，并在 stderr 留一句。
async test "the browser opens the last layer by default and clamps a bad one" {
  let options = parse_options(["demo.tar"])
  let start = start_config_of(options, 4, [])
  assert_eq(start.layer, 3)
  assert_eq(start.compare_mode, @tui.CompareMode::Single)
  assert_eq(start.path, None)
  assert_eq(start.focus, @tui.Focus::Tree)
  let only = parse_options(["demo.tar"])
  let notices : Array[String] = []
  // 单层镜像：缺省层号是下标 0，不该被当成越界
  assert_eq(start_config_of(only, 1, notices).layer, 0)
  assert_true(notices.is_empty())
  let bad = parse_options(["demo.tar", "--layer", "9"])
  let notices : Array[String] = []
  assert_eq(start_config_of(bad, 4, notices).layer, 9)
  assert_eq(notices.length(), 1)
}

///|
/// `--save` 与界面互斥（第一条硬原则的反面：不静默让谁赢）。
///
/// 「互斥」判的是**用户有没有明说要界面**，不是「终端够不够格」：`--save`
/// 先于取镜像就 return，本来就走不到选界面那一步，终端状态掺进来只会让
/// 同一份脚本在本地和 CI 里得到两种结论（issue #128 复盘）。
async test "save without --no-tui is a config error, not a silent choice" {
  let save = parse_options(["nginx:latest", "--save", "-o", "x.tar"])
  assert_true(save.save && save.interactive())
  let save_text = parse_options([
    "nginx:latest", "--save", "-o", "x.tar", "--no-tui",
  ])
  assert_false(save_text.save && save_text.interactive())
}

///|
/// 能不能开界面：`-`（stdin 是 tar）一票否决——界面会把 tar 流吃掉。
///
/// 这一档在问 tty 之前就返回，所以断言与环境无关：哪怕测试跑在真终端里也一样。
async test "an image from stdin never opens the browser" {
  let options = parse_options(["-"])
  let refusal = refusal_of_tui(options)
  assert_true(refusal is Some(_))
  let message = refusal.unwrap()
  assert_true(message.contains("stdin"))
  // 给了 `--no-tui` 就该走文本，闭嘴不提示
  assert_false(parse_options(["-", "--no-tui"]).interactive())
}

///|
/// 流式拉下来的 blob 活着读到 `ImageSource` 里，临时目录随后才被收掉
/// （issue #122 的另一半，也是 #128 的现场；#133 之后这条路不再攒 tar）。
///
/// 现场长这样：`[registry] parsing .../image.tar...` 下一行
/// `image error: cannot read image: .../image.tar: No such file or directory`。
/// 旧的 `load_from_registry` 先删临时目录再 `ImageSource::load`，
/// 删掉的正是接下来要 `fopen` 的那份文件；镜像一条都没读到，
/// 链路在「选界面」之前就 exit 2 了——于是看起来像「说好的界面没打开」。
async test "streamed blobs survive the temp cleanup, and the temp dir does not" {
  let layer = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("etc/os-release", "ID=moonbit"),
  ])
  let digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  let directory = @async_fs.tmpdir(prefix="dive-registry-") catch {
    err => fail("cannot create a temp directory: \{err}")
  }
  let path = "\{directory}/layer-0.blob"
  @async_fs.write_file(path, layer) catch {
    err => fail("cannot write the layer: \{err}")
  }
  let image : @registry_cli.StreamedImage = {
    reference: "demo:latest",
    config_json: "{ \"architecture\": \"amd64\", \"os\": \"linux\", \"rootfs\": { \"type\": \"layers\", \"diff_ids\": [\"" +
    digest +
    "\"] } }",
    layers: [
      {
        media_type: "application/vnd.oci.image.layer.v1.tar",
        digest,
        path,
        size: layer.length().to_int64(),
      },
    ],
    staging: directory,
  }
  let options = parse_options(["demo:latest", "--no-tui"])
  let source = try registry_source(options, image) catch {
    err => fail("the streamed image must be readable: \{Repr(err)}")
  } noraise {
    source => source
  }
  assert_eq(source.layers.length(), 1)
  // 读完再收：删的是临时目录，不是紧接着还要用的那份 blob
  cleanup_streamed(image, directory)
  assert_false(@fs.path_exists(path))
  // 收完还得能解析：`ImageSource` 手里是字节，不是一条指向临时目录的路径
  // （issue #138 的现场：到这一步只剩 `No such file or directory`）
  let plain = try source.layers[0].raw_bytes() catch {
    err =>
      fail("the layer must still read back after cleanup: \{err.to_string()}")
  } noraise {
    bytes => bytes
  }
  assert_eq(plain.length(), layer.length())
}
