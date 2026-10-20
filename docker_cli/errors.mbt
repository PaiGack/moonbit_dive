///|
/// 后端探测与调用的错误。区分「找不到可用后端」与「后端跑失败了」，
/// 因为前者要提示用户装什么、后者要透传子进程的 stderr 供排查。
pub(all) suberror DockerCliError {
  /// 一个后端都探测不到：既没有 unix socket，PATH 上也没有 docker/podman/nerdctl
  NoBackend(String)
  /// 探测到了后端，但执行失败（退出码非 0 / 无法 spawn / 超时）
  Backend(String, Int32, String)
  /// 找不到可执行文件
  ExecutableNotFound(String)
  /// 子进程被取消（超时或主动 cancel）。
  ///
  /// 两个字段分开，是因为两件事要分开说：**谁**被取消（`name`），
  /// 以及**为什么/等了多久**（`reason`）。合并成一个字符串的话，
  /// `Show` 只能原样吐出，调用方想在日志里只取路径、或只取耗时，都做不到。
  Cancelled(String, String)
  /// 归档格式解析失败
  Archive(String)
  /// 输入本身不合法（空镜像名等）
  InvalidReference(String)
  /// 后端答了，但答的是「没有这个镜像」（Engine 的 404）。
  ///
  /// 与 `Backend` 分开是因为这条错误**不是故障**：它是一只可用的后端
  /// 给出的确定答案，调用方可以据此走「本地没有 → 拉一次」的策略，
  /// 而不是把整条后端判成不可用。见 `ImageSource::inspect`。
  ImageNotFound(String)
} derive(Eq, Debug)

///|
pub extend DockerCliError with Eq::{equal, not_equal}

///|
pub extend DockerCliError with @debug.Debug::{to_repr}

///|
/// 错误信息面向用户：先说哪里错了，再给出可执行的下一步。
pub impl Show for DockerCliError with fn to_string(self) {
  match self {
    NoBackend(detail) =>
      "no usable docker backend: \{detail}\n" + backend_hint()
    Backend(name, code, stderr) => {
      let trimmed = stderr.trim()
      // code < 0 表示「不是子进程退出」：Engine 的 HTTP 失败、建连失败都走这条路。
      // 硬写成 `exited with code -1` 会把人往「子进程挂了」的方向带偏。
      let prefix = if code < 0 {
        "\{name} failed"
      } else {
        "\{name} exited with code \{code}"
      }
      if trimmed.is_empty() {
        prefix
      } else {
        "\{prefix}: \{trimmed}"
      }
    }
    ExecutableNotFound(name) => "executable not found: \{name}"
    // `reason` 空着时别在句尾留一个孤零零的冒号
    Cancelled(name, reason) =>
      if reason.trim().is_empty() {
        "\{name} was cancelled"
      } else {
        "\{name} was cancelled: \{reason}"
      }
    Archive(detail) => "not a readable image archive: \{detail}"
    InvalidReference(detail) => "invalid image reference: \{detail}"
    ImageNotFound(reference) => "no such image locally: \{reference}"
  }
}

///|
/// `NoBackend` 的安装提示。Windows 上念 POSIX socket 的经没有意义：
/// 那边没有 `/var/run/docker.sock`，能用的是 docker CLI（Docker Desktop
/// 的命名管道我们不走），所以提示换成「装 Docker Desktop / 把 docker 放进 PATH」。
///
/// 判平台用运行期信息而不是 `#cfg`：被裁掉的分支在 Linux CI 上根本不编译，
/// 写错了也没人知道（见 `probe.mbt` 的 `is_windows_platform`）。
pub fn backend_hint(windows_platform~ : Bool = is_windows_platform()) -> String {
  if windows_platform {
    "  put docker on PATH (e.g. Docker Desktop's C:\\Program Files\\Docker\\Docker\\resources\\bin),\n" +
    "  or set DOCKER_CLI=C:\\path\\to\\docker.exe, or pass a tar file directly"
  } else {
    "  set DOCKER_CLI=/path/to/docker, or put docker / podman / nerdctl on PATH,\n" +
    "  or run DOCKER_HOST=unix:///var/run/docker.sock, or pass a tar file directly"
  }
}

///|
pub extend DockerCliError with Show::{to_string, output}
