///|
/// 编译目标架构的 registry 叫法。
///
/// 用 `#cfg` 分支而不是运行时探测：MoonBit 没有暴露「当前 arch」的运行时接口，
/// 而镜像分析基本都是 native + linux/amd64 或 linux/arm64 两种。
/// 其它架构请用 `--platform` 或 `DIVE_PLATFORM_ARCH` 显式指定。
pub fn target_architecture() -> String {
  arch_amd64()
}

///|
#cfg(target_arch="aarch64")
fn arch_amd64() -> String {
  "arm64"
}

///|
#cfg(not(target_arch="aarch64"))
fn arch_amd64() -> String {
  "amd64"
}
