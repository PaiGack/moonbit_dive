///|
/// 解析 `docker inspect` 的输出。
///
/// docker / nerdctl 吐 JSON 数组；podman `--format json` 也是数组。
/// 单对象（某些版本 / `docker inspect --type image` 变体）也接受。
///
/// 这里只做「尽力而为」：inspect 是锦上添花的旁证，字段缺了就留空，
/// 不因为 `Size` 之类字段缺失而否决整个后端。
pub fn parse_inspect(
  tool : CliTool,
  stdout : Bytes,
  reference : String,
) -> ImageInfo raise DockerCliError {
  let text = bytes_to_string(stdout)
  let json = @json.parse(text) catch {
    err =>
      raise Backend(
        Show::to_string(tool),
        -1,
        "inspect output is not JSON: \{err}",
      )
  }
  let object = match json {
    Array(items) =>
      match items {
        [first, ..] if is_object(first) => first
        [] =>
          raise Backend(
            Show::to_string(tool),
            -1,
            "inspect returned an empty array",
          )
        _ =>
          raise Backend(
            Show::to_string(tool),
            -1,
            "inspect returned an unexpected shape",
          )
      }
    Object(_) => json
    _ =>
      raise Backend(
        Show::to_string(tool),
        -1,
        "inspect returned an unexpected shape",
      )
  }
  let fields = match object {
    Object(fields) => fields
    _ =>
      raise Backend(
        Show::to_string(tool),
        -1,
        "inspect returned an unexpected shape",
      )
  }
  {
    id: string_field(fields, "Id"),
    reference,
    architecture: string_field(fields, "Architecture"),
    os: string_field(fields, "Os"),
    size: int_field(fields, "Size"),
    virtual_size: int_field(fields, "VirtualSize"),
  }
}

///|
fn is_object(json : Json) -> Bool {
  match json {
    Object(_) => true
    _ => false
  }
}

///|
fn string_field(fields : Map[String, Json], name : String) -> String {
  match fields.get(name) {
    Some(String(value)) => value
    _ => ""
  }
}

///|
fn int_field(fields : Map[String, Json], name : String) -> Int32 {
  // docker inspect 的 Size 字段是十进制整数，但 JSON 解析器统一给 Double；
  // 大镜像的 VirtualSize 可能超过 2^53，这里按 Double 转，够用且不引入 bigint。
  match fields.get(name) {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
}

///|
/// 子进程的 stdout 是 UTF-8 文本（JSON）。
/// 用 lossy 解码而不是 `to_unchecked_string`：后者按 UTF-16 码元解释字节，
/// 会把 JSON 的 ASCII 读成乱码。
pub fn bytes_to_string(data : Bytes) -> String {
  @utf8.decode_lossy(data)
}
