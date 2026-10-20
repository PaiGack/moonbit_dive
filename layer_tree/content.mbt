///|
/// 内容比对用的一次扫描结果：路径 -> 当前内容的指纹。
///
/// 键是 tar 里的路径，值是 sha256 hex 摘要；目录、符号链接这类没有内容字节的
/// entry 也给一条记录，摘要为 `None`（它们在 `Node` 里靠 kind / mode / 属主比）。
pub struct ContentScan {
  hashes : Map[String, String?]
} derive(Debug)

///|
pub extend ContentScan with @debug.Debug::{to_repr}

///|
/// 扫描一段已解压的层 tar，算出每条 entry 的内容摘要。
///
/// 只读每条 entry 的数据段，不碰树、不碰 whiteout：调用方拿它去比两次快照里
/// 同一路径的字节是否一样。同一条路径在一层里出现两次时留最后一次
/// （与 `apply_layer` 的语义一致：后写的赢）。
pub fn content_scan(raw : BytesView) -> ContentScan {
  let hashes : Map[String, String?] = Map([])
  let reader = TarReader::new(raw)
  while true {
    // 摘要只服务于比对：入口已经校验过 tar，残缺流在这里不值得把整个比对打断
    let entry = reader.next() catch {
      err => {
        if err is NotFound {
          break
        }
        abort("content scan failed: \{err.to_string()}")
      }
    }
    let path = match entry.entry_type {
      Meta | Other(_) => continue
      _ => entry.path
    }
    let hash = if entry.size > 0 && entry.entry_type is Regular {
      Some(sha256_hex(entry.data(raw)))
    } else {
      None
    }
    // 键统一成树内绝对路径（`/etc/hosts`）：tar 里写的是相对路径，
    // 直接拿它当键会让「同一条路径」在扫描表与文件树里对不上号
    let normalized = normalize_path(path) catch { _ => continue }
    hashes.set(normalized, hash)
  }
  { hashes, }
}

///|
/// 两次扫描之间内容变了的路径，按路径序。
///
/// 两条规则：
/// - 两边都有记录且摘要不同 -> 变了（同大小、同 mtime 但字节不同也认得出）
/// - 只有一边有 -> 变了（这一层删了它 / 这一层才写出来）
///
/// 摘要同为 `None`（两边都是目录或链接）不算变化：这两类节点没有可比的字节。
pub fn content_changes(
  before : ContentScan,
  after : ContentScan,
) -> Array[String] {
  let changed = []
  for path, hash in before.hashes {
    match after.hashes.get(path) {
      None => changed.push(path)
      Some(next) =>
        if hash is Some(left) && next is Some(right) && left != right {
          changed.push(path)
        }
    }
  }
  for path, hash in after.hashes {
    if before.hashes.contains(path) {
      continue
    }
    if hash is Some(_) {
      changed.push(path)
    }
  }
  changed.sort_by(path_order)
  changed
}

///|
/// 一段字节的 sha256 摘要（全小写 hex）。
fn sha256_hex(data : BytesView) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(data))
}

///|
/// 按层的原始 tar 给整棵树补上内容摘要与写入记录。
///
/// 叠树本身不算摘要（见 `Node::digest` 的注释），这一步是「真要比内容时」的
/// 准备动作：跑过它之后 `diff_snapshots` 才认得「同大小不同内容」。
/// 多层时逐层往后推，`Node::digest` 记的是最终内容，`Node::files` 是写入流水。
pub fn FileTree::scan_content(
  self : FileTree,
  raws : Array[Bytes],
) -> Unit noraise {
  for _, node in self.nodes {
    node.digest = None
    node.files = []
  }
  for index, raw in raws {
    let scan = content_scan(raw)
    for path, hash in scan.hashes {
      let node = match self.nodes.get(path) {
        Some(node) => node
        None => continue
      }
      // 路径已经被更后面的层改写：这一层的内容不再代表终值
      if node.layer != index {
        continue
      }
      let previous = match node.digest {
        Some(previous) => previous.changes
        None => 0
      }
      node.digest = Some({ changes: previous + 1, hash, })
      let size = if hash is Some(_) { node.size } else { 0 }
      node.files.push({ layer: index, size, hash, })
    }
  }
}
