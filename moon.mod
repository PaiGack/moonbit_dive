// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "PaiGack/dive"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/PaiGack/moonbit_dive"

license = "Apache-2.0"

keywords = [ "oci", "container-image", "tar", "analysis" ]

preferred_target = "wasm"

description = "A MoonBit toolkit for analyzing OCI container images: layer stacking, whiteout diffs and size-efficiency reports"

import {
  "moonbitlang/x@0.5.5",
}
