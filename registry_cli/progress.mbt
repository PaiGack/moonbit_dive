///|
/// 一次拉取的进度事件。
///
/// 只报「事实」（已经拿到多少字节），不报「百分比」——百分比是渲染层的事：
/// 命令行要百分比，将来的 TUI 要进度条，测试要纯数字。
pub(all) enum PullEvent {
  /// 开始拉某个镜像
  Started(reference~ : String)
  /// 层数定了（manifest 读完了），`bytes` 是压缩后总量
  Plan(layers~ : Int32, bytes~ : Int64)
  /// 一层开始下载
  LayerStarted(index~ : Int32, digest~ : String, bytes~ : Int64)
  /// 一层下载中的一次进度；`received` 是这一层已拿到的字节
  LayerProgress(index~ : Int32, received~ : Int64, total~ : Int64)
  /// 一层结束
  LayerDone(index~ : Int32, bytes~ : Int64)
  /// 解压 + 打包（docker-archive 要把层解压开再套 tar，大镜像上这一步不便宜）
  Packing(note~ : String)
  /// 落盘
  Writing(path~ : String, bytes~ : Int64)
} derive(Eq, Debug)

///|
pub extend PullEvent with Eq::{equal, not_equal}

///|
pub extend PullEvent with @debug.Debug::{to_repr}

///|
pub impl Show for PullEvent with fn to_string(self) {
  match self {
    Started(reference~) => "pulling \{reference}"
    Plan(layers~, bytes~) =>
      "\{layers} layers, \{human_bytes(bytes)} to download"
    LayerStarted(index~, digest~, bytes~) =>
      "layer \{index + 1}: \{short_digest(digest)} (\{human_bytes(bytes)})"
    LayerProgress(index~, received~, total~) => {
      // 没有总量时别打 `0%`：那会让「还在下」看起来像「卡住了」
      let percent = if total > 0L {
        " (\{(received * 100L / total).to_int()}%)"
      } else {
        ""
      }
      "layer \{index + 1}: \{human_bytes(received)} / \{human_bytes(total)}\{percent}"
    }
    LayerDone(index~, bytes~) =>
      "layer \{index + 1} done (\{human_bytes(bytes)})"
    Packing(note~) => note
    Writing(path~, bytes~) => "writing \{path} (\{human_bytes(bytes)})"
  }
}

///|
pub extend PullEvent with Show::{to_string, output}

///|
/// 每收满这么多字节报一次进度。
///
/// 1 MiB 是有意的：700MB 的镜像按这个步长大约 700 次回调，
/// 每次只做几个整数除法与一次 `\r` 刷新，开销可以忽略；
/// 再小就变成「刷屏比下载还忙」，再大则肉眼觉得进度条卡住。
let progress_step : Int64 = 1024 * 1024

///|
/// `1048576` -> `1.0 MiB`。进度行的宽度按人眼来，不按字节来。
pub fn human_bytes(bytes : Int64) -> String {
  let units : Array[String] = ["B", "KiB", "MiB", "GiB", "TiB"]
  let mut value = bytes.to_double()
  let mut unit = 0
  while value >= 1024.0 && unit < units.length() - 1 {
    value = value / 1024.0
    unit = unit + 1
  }
  if unit == 0 {
    "\{bytes} B"
  } else if value >= 100.0 {
    "\{value.round().to_int()} \{units[unit]}"
  } else {
    // 保留一位小数：`1.0 MiB` 比 `1 MiB` 更容易看出还在动
    let tenths = (value * 10.0).round().to_int()
    "\{tenths / 10}.\{tenths % 10} \{units[unit]}"
  }
}

///|
/// 一小段 digest，日志里够区分就行：`sha256:1a2b3c4d5e6f`。
pub fn short_digest(digest : String) -> String {
  let colon = digest.find(":")
  let head = match colon {
    Some(index) => digest[:index + 1].to_owned()
    None => ""
  }
  let body = match colon {
    Some(index) => digest[index + 1:].to_owned()
    None => digest
  }
  if body.length() <= 12 {
    digest
  } else {
    "\{head}\{body[:12]}"
  }
}
