///|
/// 写一个假的可执行文件到临时目录，用来替代真实的 docker / podman / nerdctl。
///
/// 测试里不依赖真实 daemon：CI 上通常没有，也不该有。
/// 返回脚本路径，交给 `DockerCliSource` 当 `program` 用。
pub async fn write_fake_cli(script : String) -> String {
  let dir = @fs.tmpdir(prefix="dive-fake-cli-")
  let path = "\{dir}/fake-docker"
  @fs.write_file(path, script, permission=0o755)
  path
}

///|
/// 删掉 `write_fake_cli` 建出来的临时目录。
#warnings("-unused_async")
pub async fn remove_fake_cli(path : String) -> Unit {
  let dir = parent_dir(path)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => path[:index].to_owned()
    None => path
  }
}

///|
/// 造一个「`inspect` 成功、`save` 成功」的假 docker。
///
/// 脚本用 heredoc 把归档写到 stdout，避免 shell 层的转义差异；
/// 归档字节先用 `@fs.write_file` 落到临时文件，脚本再 `cat` 出去。
pub fn fake_inspect_and_save(
  archive_path : String,
  inspect_json : String,
) -> String {
  let script =
    #|#!/bin/sh
    #|case "$1" in
    #|  inspect)
    #|    printf '%s' 'INSPECT_JSON'
    #|    ;;
    #|  save)
    #|    cat 'ARCHIVE_PATH'
    #|    ;;
    #|  *)
    #|    echo "unexpected command: $1" >&2
    #|    exit 2
    #|    ;;
    #|esac
    #|
  script
  .replace(old="INSPECT_JSON", new=inspect_json)
  .replace(old="ARCHIVE_PATH", new=archive_path)
}

///|
/// 造一个「`inspect` 报错」的假 docker：非零退出 + stderr 有内容，
/// 用来验证错误信息会透传子进程的 stderr。
pub fn fake_failing_cli(message : String, code : Int32) -> String {
  let script =
    #|#!/bin/sh
    #|echo "MSG" >&2
    #|exit CODE
    #|
  script
  .replace(old="MSG", new=message)
  .replace(old="CODE", new=code.to_string())
}

///|
/// 造一个永远不返回的假 docker，用来验证超时取消。
pub async fn fake_hanging_cli() -> String {
  let script =
    #|#!/bin/sh
    #|sleep 30
    #|
  write_fake_cli(script)
}

///|
/// 把字节写进临时文件，返回路径。
pub async fn write_temp_bytes(name : String, content : Bytes) -> String {
  let dir = @fs.tmpdir(prefix="dive-archive-")
  let path = "\{dir}/\{name}"
  @fs.write_file(path, content)
  path
}

///|
/// 删掉 `write_temp_bytes` 建的临时目录。
pub async fn remove_temp_bytes(path : String) -> Unit {
  let dir = parent_dir(path)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
/// 造一个只会 `cat <archive_path>` 的假 docker。
///
/// 与 `fake_inspect_and_save` 分开：大归档的用例只关心 `save`，
/// 让脚本尽量简单，别在 shell 层引入额外开销。
/// 归档由 `write_large_archive` 流式生成，脚本只负责把它转出去。
pub fn fake_cat_cli(archive_path : String) -> String {
  let script =
    #|#!/bin/sh
    #|case "$1" in
    #|  save)
    #|    cat 'ARCHIVE_PATH'
    #|    ;;
    #|  *)
    #|    echo "unexpected command: $1" >&2
    #|    exit 2
    #|    ;;
    #|esac
    #|
  script.replace(old="ARCHIVE_PATH", new=archive_path)
}

///|
/// 写一个名字可指定的假可执行文件到临时目录，返回 (目录, 文件路径)。
///
/// `write_fake_cli` 固定写 `fake-docker`，适合直接构造 `DockerCliSource`；
/// 但探测链路按 PATH 找的是**工具名本身**（`docker` / `podman` / `nerdctl`），
/// 所以端到端验证 `fetch_archive` 需要一个真叫 `docker` 的文件。
/// 配套的清理用 `@fs.remove_dir(dir, recursive=true)` 更省事，这里就返回目录。
pub async fn write_fake_cli_named(
  name : String,
  script : String,
) -> (String, String) {
  let dir = @fs.tmpdir(prefix="dive-fake-cli-")
  let path = "\{dir}/\{name}"
  @fs.write_file(path, script, permission=0o755)
  (dir, path)
}

///|
/// 删掉 `write_fake_cli_named` 建出来的临时目录。
pub async fn remove_fake_cli_dir(dir : String) -> Unit {
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}
