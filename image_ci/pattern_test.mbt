///|
/// 字面量模式：整段匹配，不做前缀。
async test "literal pattern" {
  let pattern = PathPattern::compile("/usr/bin/sh")
  assert_true(pattern.matches("/usr/bin/sh"))
  assert_false(pattern.matches("/usr/bin"))
  assert_false(pattern.matches("/usr/bin/shx"))
  assert_false(pattern.matches("/usr/bin/sh/extra"))
}

///|
/// 相对写法会被补上前导 `/`。
async test "relative pattern" {
  let pattern = PathPattern::compile("usr/bin")
  assert_true(pattern.matches("/usr/bin"))
  assert_eq(pattern.raw, "/usr/bin")
}

///|
/// `**` 匹配任意多段（含零段）。
async test "double star" {
  let pattern = PathPattern::compile("/app/node_modules/**")
  assert_true(pattern.matches("/app/node_modules"))
  assert_true(pattern.matches("/app/node_modules/react/index.js"))
  assert_true(pattern.matches("/app/node_modules/a/b/c/d.js"))
  assert_false(pattern.matches("/app/src/index.js"))

  let middle = PathPattern::compile("/usr/**/cache")
  assert_true(middle.matches("/usr/cache"))
  assert_true(middle.matches("/usr/lib/apt/cache"))
  assert_false(middle.matches("/usr/lib/apt/cache/entry"))
}

///|
/// `*` 只在单段内通配。
async test "single star" {
  let pattern = PathPattern::compile("/app/*.log")
  assert_true(pattern.matches("/app/build.log"))
  assert_true(pattern.matches("/app/.log"))
  assert_false(pattern.matches("/app/logs/build.log"))

  let prefix = PathPattern::compile("/app/*")
  assert_true(prefix.matches("/app/main.js"))
  assert_false(prefix.matches("/app/src/main.js"))

  let suffix = PathPattern::compile("/app/*-debug")
  assert_true(suffix.matches("/app/app-debug"))
  assert_false(suffix.matches("/app/app-release"))
}

///|
/// 以 `/` 结尾的模式按子树匹配。
async test "subtree pattern" {
  let pattern = PathPattern::compile("/var/log/")
  assert_true(pattern.matches("/var/log/syslog"))
  assert_true(pattern.matches("/var/log/nginx/access.log"))
}

///|
/// 目录匹配：过滤器把整棵树当路径看。
async test "filter render and covers" {
  let recursive = PathFilter::new(PathPattern::compile("/usr/lib/**"))
  assert_true(recursive.covers("/usr/lib/libc.so"))
  assert_true(recursive.covers("/usr/lib/x86_64/thing.so"))
  assert_false(recursive.covers("/usr/bin/sh"))

  let direct = PathFilter::new(
    PathPattern::compile("/usr/lib/*"),
    recursive=false,
  )
  assert_true(direct.covers("/usr/lib/libc.so"))
  assert_false(direct.covers("/usr/lib/x86_64/thing.so"))
  assert_eq(direct.render(), "/usr/lib/* (direct children only)")
}
