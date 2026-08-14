///|
test "Codex projects use shared project component input" {
  let state = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "thread-1",
      "cwd": "/work/openseek",
      "projectRoot": "/work/openseek",
      "preview": "Inspect sidebar",
      "turns": [],
    },
  })
  let entries = state.sidebar_component_entries({
    channel: "local",
    selected: true,
    project_registered: path => path == "/work/openseek",
    project_label: _ => "openseek",
  })
  assert_eq(entries.length(), 1)
  guard entries[0] is @section.Project(row) else {
    fail("expected shared project component input")
  }
  assert_true(row.active)
  assert_true(row.managed)
  assert_eq(row.id().source(), "codex")
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
  let entries = state.sidebar_component_entries({
    channel: "local",
    selected: true,
    project_registered: _ => false,
    project_label: path => path,
  })
  assert_eq(entries.length(), 1)
  guard entries[0] is @section.Conversation(row) else {
    fail("expected a direct Codex conversation row")
  }
  assert_false(row.nested)
  assert_true(row.active)
}
