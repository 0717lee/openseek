///|
test "equal paths from different sources have independent component keys" {
  let live = Id(
    source="openseek.projects",
    channel="local",
    root="/work/openseek",
  )
  let archived = Id(
    source="openseek.archived",
    channel="local",
    root="/work/openseek",
  )
  assert_true(live != archived)
  assert_true(live.subscription_key() != archived.subscription_key())
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
