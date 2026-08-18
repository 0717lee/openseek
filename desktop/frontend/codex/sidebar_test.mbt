///|
test "Codex threads nest under their registered project row" {
  let state = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "thread-1",
      "cwd": "/work/openseek",
      "projectRoot": "/work/openseek",
      "preview": "Inspect sidebar",
      "turns": [],
    },
  })
  let context : @codex.SidebarContext = {
    channel: @interop.ChannelId::Local,
    selected: true,
    registered_projects: ["/work/openseek"],
  }
  let conversations = state.project_conversations(context, "/work/openseek")
  assert_eq(conversations.length(), 1)
  assert_true(conversations[0].input.nested)
  assert_eq(
    state.project_activation(context, "/work/openseek"),
    Some("thread-1"),
  )
  assert_eq(state.project_activation(context, "/work/other"), None)
  assert_eq(state.loose_entries(context).length(), 0)
}

///|
test "unregistered Codex roots remain direct conversation inputs" {
  let state = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "thread-1",
      "cwd": "/work/scratch",
      "projectRoot": "/work/scratch",
      "preview": "Inspect scratch",
      "turns": [],
    },
  })
  let context : @codex.SidebarContext = {
    channel: @interop.ChannelId::Local,
    selected: true,
    registered_projects: [],
  }
  assert_eq(state.project_conversations(context, "/work/scratch").length(), 0)
  let entries = state.loose_entries(context)
  assert_eq(entries.length(), 1)
  guard entries[0] is @section.Conversation(row) else {
    fail("expected a direct Codex conversation input")
  }
  assert_false(row.nested)
  assert_true(row.active)
}
