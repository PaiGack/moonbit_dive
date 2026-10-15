///|
/// 夹在 `[low, high]` 内；`high < low` 时返回 `low`。
pub fn clamp(value : Int32, low : Int32, high : Int32) -> Int32 {
  if high < low {
    return low
  }
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
/// 取大者。
pub fn max(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// 取小者。
pub fn min(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// 光标不在可见行里时（比如它所在的子树被折叠了），退到离它最近的可见行。
///
/// `visible` 已按路径排序，`hint` 是折叠前的下标：直接夹到合法范围即可——
/// 排序稳定，前后邻居就是它折叠后的落点。
fn nearest_visible(visible : Array[Row], hint : Int32) -> Int32 {
  clamp(hint, 0, visible.length() - 1)
}
