///|
/// 一层 tar 的「计划」：不改树，只把这一层会做什么列清楚。
///
/// 提前列清单是为了让记账与落树解耦——落树之后旧值就查不到了。
priv struct LayerPlan {
  /// 本层写入的条目（顺序即 tar 顺序，重复路径按最后一次为准去重）
  entries : Array[PlanEntry]
  /// 被 whiteout 删除的路径（含子树），已展开到叶子
  deleted : Array[String]
  /// 被 opaque 抹掉的旧路径（不含本层重新写入的）
  erased : Array[String]
}

///|
/// 一次写入：路径 + 本条目的字节数。
priv struct PlanEntry {
  path : String
  size : Int32
}

///|
/// 扫一层 tar，得到写入 / 删除 / 抹掉的清单。
fn scan_layer(raw : BytesView) -> LayerPlan raise @layer_tree.TarError {
  let entries : Map[String, PlanEntry] = Map([])
  let deleted : Map[String, Bool] = Map([])
  let opaque_dirs : Array[String] = []
  // 本层写过哪些路径、写到哪个目录下，供 opaque 判断「谁是本层新写的」
  let written : Map[String, Bool] = Map([])
  let reader = @layer_tree.TarReader::new(raw)
  while true {
    let entry = match reader.next() {
      None => break
      Some(entry) => entry
    }
    let path = match @layer_tree.normalize_path(entry.path) {
      Ok(path) => path
      Err(_) => continue
    }
    match @layer_tree.whiteout_kind(path) {
      Some(@layer_tree.WhiteoutKind::Entry(name)) => {
        let target = @layer_tree.join_path(@layer_tree.parent_path(path), name)
        mark_deleted(deleted, target)
        continue
      }
      Some(@layer_tree.WhiteoutKind::Opaque) => {
        opaque_dirs.push(@layer_tree.parent_path(path))
        continue
      }
      Some(@layer_tree.WhiteoutKind::Plnk) => continue
      None => ()
    }
    if path == "/" ||
      entry.entry_type
      is (@layer_tree.TarEntryType::Meta | @layer_tree.TarEntryType::Other(_)) {
      continue
    }
    let size = if entry.entry_type is @layer_tree.TarEntryType::Regular {
      entry.size
    } else {
      0
    }
    entries.set(path, { path, size, })
    written.set(path, true)
    // 目录 entry 视为「把该目录列出来」，也纳入 whiteout 的展开范围
  }
  let deleted_paths = []
  for path, _ in deleted {
    deleted_paths.push(path)
  }
  deleted_paths.sort_by(@layer_tree.path_order)
  { entries: to_entries(entries), deleted: deleted_paths, erased: opaque_dirs, }
}

///|
/// map 转有序数组，路径序稳定，保证报告可快照。
fn to_entries(entries : Map[String, PlanEntry]) -> Array[PlanEntry] {
  let result = []
  for _, entry in entries {
    result.push(entry)
  }
  result.sort_by(fn(left, right) {
    @layer_tree.path_order(left.path, right.path)
  })
  result
}

///|
/// 标一个路径为「被删除」，同时也标它的子路径（tar 里 whiteout 目录时子树一并消失）。
fn mark_deleted(deleted : Map[String, Bool], path : String) -> Unit {
  deleted.set(path, true)
}
