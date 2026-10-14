///|
/// 进程退出：把「判定退出码」这件事集中在一处。
///
/// `moon run` 默认跑 wasm，`exit` 在 wasm 里只能退化成 trap（拿不到退出码），
/// 因此以 native 为主：`moon run --target native cmd/main`。
/// wasm 下的降级行为写在这里，免得调用方察觉不到差别。
#cfg(any(target="native", target="llvm"))
extern "c" fn native_exit(code : Int32) = "exit"

///|
/// 退出码约定（与 `image_ci` 保持一致）：
/// `0` 全过、`1` 有规则未通过、`2` 规则非法或镜像读不出来。
fn exit_process(code : Int32) -> Unit {
  exit_platform(code)
}

///|
/// native / llvm 直接调 C 的 `exit`，退出码原样传给 shell。
#cfg(any(target="native", target="llvm"))
fn exit_platform(code : Int32) -> Unit {
  native_exit(code)
}

///|
/// wasm 后端没有稳定的退出码通道：能打印的已经打印过了，
/// 这里用 trap 让构建明确失败（CI 靠输出判读具体是 1 还是 2）。
#cfg(not(any(target="native", target="llvm")))
fn exit_platform(code : Int32) -> Unit {
  if code != 0 {
    abort(
      "dive: exiting with code \{code} (run with --target native to propagate it)",
    )
  }
}
