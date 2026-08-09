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
