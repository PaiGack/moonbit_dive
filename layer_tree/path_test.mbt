///|
test "normalize_path collapses redundant segments" {
  assert_eq(normalize_path("/usr/./local//bin/").unwrap(), "/usr/local/bin")
  assert_eq(normalize_path("usr/local/bin").unwrap(), "/usr/local/bin")
  assert_eq(normalize_path("/a/b/../c").unwrap(), "/a/c")
  assert_eq(normalize_path("/").unwrap(), "/")
  assert_eq(normalize_path("./").unwrap(), "/")
  assert_eq(normalize_path("//").unwrap(), "/")
}

///|
test "normalize_path rejects escapes above the root" {
  assert_eq(normalize_path("../etc/passwd"), Err(Escape("../etc/passwd")))
  assert_eq(normalize_path("/a/../../b"), Err(Escape("/a/../../b")))
  // 回退到根是允许的，只有越过根才报错
  assert_eq(normalize_path("/a/../b").unwrap(), "/b")
}

///|
test "parent_path and base_name walk the tree" {
  assert_eq(parent_path("/usr/local/bin"), "/usr/local")
  assert_eq(parent_path("/usr"), "/")
  assert_eq(parent_path("/"), "/")
  assert_eq(base_name("/usr/local/bin"), "bin")
  assert_eq(base_name("/"), "")
}

///|
test "join_path and path_is_under agree on subtree membership" {
  assert_eq(join_path("/etc", "ssl/certs"), "/etc/ssl/certs")
  assert_eq(join_path("/", "etc"), "/etc")
  assert_true(path_is_under("/etc/ssl/certs", "/etc"))
  assert_true(path_is_under("/etc", "/etc"))
  assert_false(path_is_under("/etcd", "/etc"))
  assert_true(path_is_under("/anything", "/"))
}

///|
test "path_depth counts segments below the root" {
  assert_eq(path_depth("/"), 0)
  assert_eq(path_depth("/usr"), 1)
  assert_eq(path_depth("/usr/local/bin"), 3)
}
