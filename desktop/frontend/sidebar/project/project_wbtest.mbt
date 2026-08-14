///|
test "equal paths from different sources have independent component keys" {
  let openseek = Id(
    source="openseek.projects",
    channel="local",
    root="/work/openseek",
  )
  let codex = Id(source="codex", channel="local", root="/work/openseek")
  assert_true(openseek != codex)
  assert_true(openseek.subscription_key() != codex.subscription_key())
}

///|
test "the project component state owns its compact preview" {
  let state : State = {
    collapsed: false,
    preview_expanded: false,
    menu_open: false,
  }
  assert_true(state.conversation_visible(4, false))
  assert_false(state.conversation_visible(5, false))
  assert_true(state.conversation_visible(5, true))
  let expanded = state.update(ShowMore)
  assert_true(expanded.conversation_visible(5, false))
}
