///|
test "in-place model replacement preserves view state" {
  let current = @common.Uri::from(
    scheme="openseek",
    authority="local",
    path="/work/src/main.mbt",
  )
  let other = @common.Uri::from(
    scheme="openseek",
    authority="local",
    path="/work/src/other.mbt",
  )
  assert_true(should_restore_view_state(false, Some(current), current))
  assert_false(should_restore_view_state(false, Some(other), current))
  assert_false(should_restore_view_state(false, None, current))
  assert_true(should_restore_view_state(true, Some(other), current))
}

///|
test "symbol navigation highlights the exact target without a selection" {
  let range = @common.Range(7, 3, 7, 12)
  let target = navigation_target_presentation(range)
  assert_eq(target.position, @common.Position(7, 3))
  assert_eq(target.decoration.range, range)
  assert_eq(target.decoration.options.class_name, "symbolHighlight")
  assert_eq(
    target.decoration.options.description,
    "symbol-navigate-action-highlight",
  )
  assert_false(target.decoration.options.is_whole_line)
}

///|
test "point navigation keeps its column and highlights the whole line" {
  let target = navigation_target_presentation(@common.Range(9, 17, 9, 17))
  assert_eq(target.position, @common.Position(9, 17))
  assert_eq(target.decoration.range, @common.Range(9, 1, 9, 1))
  assert_eq(target.decoration.options.class_name, "rangeHighlight")
  assert_eq(target.decoration.options.description, "point-range-line-highlight")
  assert_true(target.decoration.options.is_whole_line)
}
