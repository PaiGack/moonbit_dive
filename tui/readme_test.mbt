///|
/// README 里的示例：建视图状态、走行、折叠、换层。
test "README example" {
  // 造一个两层的树：L1 把 /app/main 改写了
  let l0 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::Dir("app"),
    @layer_tree.TarEntrySpec::File("app/main", "x"),
  ])
  let l1 = @layer_tree.build_tar([
    @layer_tree.TarEntrySpec::File("app/main", "yyyy"),
  ])
  let views = @layer_tree.browse_layers([l0, l1]) catch {
    err => fail(err.to_string())
  }

  // 建视图状态：默认看第 0 层
  let state = @tui.AppState::new(views, None, "demo:latest")
  assert_eq(state.view.layer, 0)
  assert_eq(state.view.visible.length(), 2)

  // 走行 + 折叠 + 换层
  state.view.move_down()
  assert_eq(state.view.cursor, 1)
  state.view.move_to(state.view.index_of_path("/app").unwrap())
  state.view.toggle()
  assert_true(state.view.collapsed.contains("/app"))
  state.switch_layer(1)
  assert_eq(state.view.layer, 1)
}
