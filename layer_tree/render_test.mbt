///|
/// 渲染样本：目录、文件、软链、硬链各一份。
fn render_sample_tree() -> FileTree raise {
  let tree = FileTree::new()
  apply_layer(
    tree,
    build_tar([
      Dir("app"),
      File("app/main.js", "console.log(1)"),
      File("app/README.md", "# readme"),
      Symlink("app/index.js", "main.js"),
      Hardlink("app/copy.js", "main.js"),
    ]),
    0,
  )
  tree
}

///|
test "render_tree draws an indented tree" {
  let rendered = render_tree(render_sample_tree()) catch {
    err => fail("sample tree should build: \{err.to_string()}")
  }
  inspect(
    rendered,
    content=(
      #|/
      #|  app/ [L0]
      #|    README.md (8 bytes) [L0]
      #|    copy.js ==> /app/main.js [L0]
      #|    index.js -> main.js [L0]
      #|    main.js (14 bytes) [L0]
      #|
    ),
  )
}

///|
test "render_tree honours minimal options" {
  let rendered = render_tree(
    render_sample_tree(),
    options=minimal_render_options,
  ) catch {
    err => fail("sample tree should build: \{err.to_string()}")
  }
  inspect(
    rendered,
    content=(
      #|/
      #|  app/
      #|    README.md
      #|    copy.js ==> /app/main.js
      #|    index.js -> main.js
      #|    main.js
      #|
    ),
  )
}

///|
test "render_tree_between only shows the layers in range" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([Dir("etc"), File("etc/a.conf", "a")]), 0) catch {
    err => fail("layer 0 should apply: \{err.to_string()}")
  }
  apply_layer(tree, build_tar([File("etc/b.conf", "b")]), 1) catch {
    err => fail("layer 1 should apply: \{err.to_string()}")
  }
  inspect(
    render_tree_between(tree, 0, 1),
    content=(
      #|L0 -> L1
      #|  etc/ [L0]
      #|    b.conf (1 bytes) [L1]
      #|
    ),
  )
}

///|
test "render_diff groups added, modified and removed" {
  let tree = FileTree::new()
  apply_layer(
    tree,
    build_tar([Dir("etc"), File("etc/keep", "1"), File("etc/gone", "2")]),
    0,
  ) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  let before = tree.snapshot()
  apply_layer(
    tree,
    build_tar([
      Whiteout("etc", "gone"),
      File("etc/keep", "22"),
      File("etc/new", "3"),
    ]),
    1,
  ) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  let diff = diff_snapshots(before, tree.snapshot(), 0, 1)
  inspect(
    render_diff(diff),
    content=(
      #|L0 -> L1
      #|  added: 1
      #|    /etc/new
      #|  modified: 1
      #|    /etc/keep
      #|  removed: 1
      #|    /etc/gone
      #|
    ),
  )
}

///|
test "siblings render in byte order" {
  let tree = FileTree::new()
  apply_layer(
    tree,
    build_tar([File("z", "1"), File("a", "1"), File("M", "1")]),
    0,
  ) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  inspect(
    render_tree(tree, options=minimal_render_options),
    content=(
      #|/
      #|  M
      #|  a
      #|  z
      #|
    ),
  )
}

///|
test "diff counts are stable and empty diffs render cleanly" {
  let tree = FileTree::new()
  apply_layer(tree, build_tar([File("a", "1")]), 0) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  let same = diff_snapshots(tree.snapshot(), tree.snapshot(), 0, 0)
  assert_true(same.is_empty())
  assert_eq(same.total(), 0)
  assert_eq(
    render_diff(same),
    "L0 -> L0\n  added: 0\n  modified: 0\n  removed: 0\n",
  )
}

///|
test "renderer provides sensible defaults when options are omitted" {
  // 显式传入与省略 options 应给出同一结果
  let tree = render_sample_tree() catch {
    err => fail("sample tree should build: \{err.to_string()}")
  }
  assert_eq(
    render_tree(tree),
    render_tree(tree, options=default_render_options),
  )
  assert_true(render_tree(tree).contains("[L0]"))
  assert_false(
    render_tree(tree, options=minimal_render_options).contains("[L0]"),
  )
}

///|
test "renderer hides link targets when asked" {
  let tree = render_sample_tree() catch {
    err => fail("sample tree should build: \{err.to_string()}")
  }
  let options : RenderOptions = {
    show_size: false,
    show_layer: false,
    show_links: false,
  }
  let rendered = render_tree(tree, options~)
  assert_false(rendered.contains("->"))
  assert_false(rendered.contains("==>"))
  assert_true(rendered.contains("index.js"))
}

///|
test "render_tree_between indents nested changes under unchanged parents" {
  let tree = FileTree::new()
  apply_layer(
    tree,
    build_tar([Dir("a"), Dir("a/b"), Dir("a/b/c"), File("a/b/c/old", "1")]),
    0,
  ) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  apply_layer(tree, build_tar([File("a/b/c/new", "2")]), 1) catch {
    err => fail("layer should apply: \{err.to_string()}")
  }
  inspect(
    render_tree_between(tree, 0, 1),
    content=(
      #|L0 -> L1
      #|  a/ [L0]
      #|    b/ [L0]
      #|      c/ [L0]
      #|        new (1 bytes) [L1]
      #|
    ),
  )
}
