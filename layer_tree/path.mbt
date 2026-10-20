///|
/// 路径规范化错误：绝对路径逃逸出根目录。
pub(all) suberror PathError {
  /// 规范化后越过了根，如 `../etc/passwd`
  Escape(String)
} derive(Eq, Debug)

///|
pub extend PathError with Eq::{equal, not_equal}

///|
pub extend PathError with @debug.Debug::{to_repr}

///|
pub impl Show for PathError with fn to_string(self) {
  match self {
    Escape(raw) => "path \"\{raw}\" escapes the tree root"
  }
}

///|
pub extend PathError with Show::{to_string, output}

///|
/// 把 tar entry 名规范化成树内的绝对路径。
///
/// 规则（对齐 OCI layer 与 POSIX path 语义）：
/// - 相对路径按根补 `/`；`/./a` 里的 `.` 段丢弃
/// - 重复 `/` 折叠；结尾 `/` 去掉（根保持 `/`）
/// - `..` 逐段回退，越过根时报 `Escape`
///
/// 结果始终以 `/` 开头，根为 `"/"`。
pub fn normalize_path(raw : String) -> String raise PathError {
  let segments : Array[String] = []
  for segment in raw.split("/") {
    // `for` 迭代 StringView：比较与判空都在 view 上做，避免临时 String
    if segment == "" || segment == "." {
      continue
    }
    if segment == ".." {
      if segments.is_empty() {
        raise Escape(raw)
      }
      segments.pop() |> ignore
    } else {
      segments.push(segment.to_owned())
    }
  }
  if segments.is_empty() {
    return "/"
  }
  "/" + segments.join("/")
}

///|
/// 对已可信的路径做兜底规范化，失败时返回 `"/"`。
///
/// 用于 `parent` / `join` 等内部组合，此时输入必然来自已规范化的父路径。
fn normalize_path_lossy(raw : String) -> String {
  normalize_path(raw) catch {
    _ => "/"
  }
}

///|
/// 父目录：`/a/b` -> `/a`，根的父目录仍是根。
pub fn parent_path(path : String) -> String {
  if path == "/" || path.is_empty() {
    return "/"
  }
  match path.rev_find("/") {
    Some(index) if index == 0 => "/"
    Some(index) => path[:index].to_owned()
    None => "/"
  }
}

///|
/// 路径最后一段：`/a/b` -> `b`，根返回空串。
pub fn base_name(path : String) -> String {
  if path == "/" || path.is_empty() {
    return ""
  }
  match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
}

///|
/// 把子路径接到父路径下并规范化。
pub fn join_path(parent : String, child : String) -> String {
  if child.is_empty() {
    return if parent.is_empty() { "/" } else { parent }
  }
  let base = if parent.is_empty() || parent == "/" { "" } else { parent }
  normalize_path_lossy("\{base}/\{child}")
}

///|
/// 路径是否等于 `prefix` 或位于其子树内。
///
/// 用于 whiteout 的目录级删除与 diff 的子树比对。
pub fn path_is_under(path : String, prefix : String) -> Bool {
  if prefix == "/" {
    return true
  }
  path == prefix ||
  (path.length() > prefix.length() && path.has_prefix(prefix + "/"))
}

///|
/// 计算相对根的深度，根为 0：`/a/b` -> 2。
pub fn path_depth(path : String) -> Int32 {
  if path == "/" || path.is_empty() {
    return 0
  }
  let mut depth = 0
  for segment in path.split("/") {
    if segment != "" {
      depth = depth + 1
    }
  }
  depth
}

///|
/// 路径顺序比较：先比段数，再逐段比较。
///
/// 这样 `/a/b` 排在 `/a/c` 前、`/a` 排在 `/a/b` 前，形成自然的树状顺序；
/// 直接用字符串比较会把 `/` 与字母的大小关系带进来，结果不直观。
pub fn path_order(left : String, right : String) -> Int32 {
  let left_segments : Array[String] = []
  for segment in left.split("/") {
    left_segments.push(segment.to_owned())
  }
  let right_segments : Array[String] = []
  for segment in right.split("/") {
    right_segments.push(segment.to_owned())
  }
  let mut index = 0
  while index < left_segments.length() && index < right_segments.length() {
    let order = compare_ascii(left_segments[index], right_segments[index])
    if order != 0 {
      return order
    }
    index = index + 1
  }
  // 前缀相同：短的在前，父目录先于子节点
  if left_segments.length() < right_segments.length() {
    -1
  } else if left_segments.length() > right_segments.length() {
    1
  } else {
    0
  }
} ///|
/// 逐字节比较两个字符串，返回 -1 / 0 / 1。
///
/// 走字节比较而不是 String 的 `<`：后者并非字典序（`"m" < "R"` 为 false），
/// 用它排序会得到难以预期的顺序，渲染与快照都不稳定。

///|
pub fn compare_ascii(left : String, right : String) -> Int32 {
  let left_length = left.length()
  let right_length = right.length()
  let limit = if left_length < right_length {
    left_length
  } else {
    right_length
  }
  let mut index = 0
  while index < limit {
    let l = left.code_unit_at(index)
    let r = right.code_unit_at(index)
    if l < r {
      return -1
    } else if l > r {
      return 1
    }
    index = index + 1
  }
  if left_length < right_length {
    -1
  } else if left_length > right_length {
    1
  } else {
    0
  }
}

///|
/// 权限位 → `-rw-r--r--` 形态（10 列，dive 的 `MetadataString` 同款）。
///
/// 只做展示：`mode` 本身是低 12 位权限字面量（见 `Node::mode`），
/// 这里不管 setuid/setgid/sticky（那三位不进这 9 列），
/// 也不按 umask 或实际可执行性做判定——`0o644` 就是 `-rw-r--r--`。
///
/// `kind` 决定首字符：目录 `d`、软链 `l`、硬链 `h`，其余按普通文件。
pub fn permission_string(mode : Int32, kind : NodeKind) -> String {
  let mut text = match kind {
    Directory => "d"
    Symlink(_) => "l"
    Hardlink(_) => "h"
    File => "-"
  }
  let bits : Array[Int32] = [
    0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001,
  ]
  let chars = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
  for index, bit in bits {
    let mark = if (mode & bit) != 0 { chars[index] } else { "-" }
    text = text + mark
  }
  text
}
