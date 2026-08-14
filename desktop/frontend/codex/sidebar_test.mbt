///|
test "Codex projects use the shared workspace disclosure" {
  let state = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "thread-1",
      "cwd": "/work/openseek",
      "projectRoot": "/work/openseek",
      "preview": "Inspect sidebar",
      "turns": [],
    },
  })
  let entries = state.sidebar_entries({
    selected: true,
    open: @cmd.none,
    start_thread: _ => @cmd.none,
    open_thread: _ => @cmd.none,
    archive_thread: _ => @cmd.none,
    unarchive_thread: _ => @cmd.none,
    project_registered: path => path == "/work/openseek",
    project_collapsed: path => path == "/work/openseek",
    toggle_project: _ => @cmd.none,
    project_menu: _ => {
      Some({
        title: "More actions",
        open: false,
        toggle: @cmd.none,
        body: () => @html.nothing,
      })
    },
    project_label: _ => "openseek",
  })
  assert_eq(entries.length(), 1)
  guard entries[0] is @sidebar.Workspace(row) &&
    row.disclosure is Some(disclosure) else {
    fail("expected a collapsible shared workspace row")
  }
  assert_true(row.active)
  assert_true(disclosure.collapsed)
  assert_true(row.menu is Some(_))
}

///|
test "unregistered Codex roots remain direct conversation rows" {
  let state = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "thread-1",
      "cwd": "/work/scratch",
      "projectRoot": "/work/scratch",
      "preview": "Inspect scratch",
      "turns": [],
    },
  })
  let entries = state.sidebar_entries({
    selected: true,
    open: @cmd.none,
    start_thread: _ => @cmd.none,
    open_thread: _ => @cmd.none,
    archive_thread: _ => @cmd.none,
    unarchive_thread: _ => @cmd.none,
    project_registered: _ => false,
    project_collapsed: _ => false,
    toggle_project: _ => @cmd.none,
    project_menu: _ => None,
    project_label: path => path,
  })
  assert_eq(entries.length(), 1)
  guard entries[0] is @sidebar.Conversation(row) else {
    fail("expected a direct Codex conversation row")
  }
  assert_false(row.nested)
  assert_true(row.active)
}
