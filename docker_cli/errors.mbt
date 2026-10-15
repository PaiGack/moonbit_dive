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
  /// 子进程被取消（超时或主动 cancel）
  Cancelled(String)
  /// 归档格式解析失败
  Archive(String)
  /// 输入本身不合法（空镜像名等）
  InvalidReference(String)
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
      "no usable docker backend: \{detail}\n" +
      "  set DOCKER_CLI=/path/to/docker, or put docker / podman / nerdctl on PATH,\n" +
      "  or run DOCKER_HOST=unix:///var/run/docker.sock, or pass a tar file directly"
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
    Cancelled(name) => "\{name} was cancelled"
    Archive(detail) => "not a readable image archive: \{detail}"
    InvalidReference(detail) => "invalid image reference: \{detail}"
  }
}

///|
pub extend DockerCliError with Show::{to_string, output}
