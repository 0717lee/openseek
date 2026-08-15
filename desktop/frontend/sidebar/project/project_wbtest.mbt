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
fn test_input(activation? : String) -> Input {
  {
    id: Id(source="openseek.projects", channel="local", root="/work/openseek"),
    title: "/work/openseek",
    label: "openseek",
    activation,
    can_start: true,
    managed: true,
    conversations: [],
    empty_label: None,
  }
}

///|
test "the project component state owns its compact preview" {
  let state : State = { fold: Open, preview_expanded: false, menu_open: false }
  assert_true(state.conversation_visible(4, false))
  assert_false(state.conversation_visible(5, false))
  assert_true(state.conversation_visible(5, true))
  let expanded = state.update(test_input(), ShowMore)
  assert_true(expanded.conversation_visible(5, false))
}

///|
/// The regression behind this state shape: folding the project you are
/// inside must take effect immediately, not silently arm a fold that fires
/// when the activation later moves away.
test "folding the active project folds it immediately and stays put" {
  let open : State = { fold: Open, preview_expanded: false, menu_open: false }
  let folded = open.update(test_input(activation="desktop-a"), ToggleDisclosure)
  assert_true(folded.folded(test_input(activation="desktop-a")))
  // Leaving the branch, and returning to the same conversation, both respect
  // the explicit fold.
  assert_true(folded.folded(test_input()))
  assert_true(folded.folded(test_input(activation="desktop-a")))
  // A different activation is a jump into the branch: reveal it.
  assert_false(folded.folded(test_input(activation="desktop-b")))
}

///|
test "a fold made outside the branch is revealed by any activation" {
  let open : State = { fold: Open, preview_expanded: false, menu_open: false }
  let folded = open.update(test_input(), ToggleDisclosure)
  assert_true(folded.folded(test_input()))
  assert_false(folded.folded(test_input(activation="desktop-a")))
}

///|
test "toggling a revealed branch folds what the user sees" {
  let open : State = { fold: Open, preview_expanded: false, menu_open: false }
  // Folded while inactive, then revealed by an activation…
  let folded = open.update(test_input(), ToggleDisclosure)
  let revealed_input = test_input(activation="desktop-a")
  assert_false(folded.folded(revealed_input))
  // …a click now means "fold", not "flip the stale stored value to open".
  let refolded = folded.update(revealed_input, ToggleDisclosure)
  assert_true(refolded.folded(revealed_input))
}
