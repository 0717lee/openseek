///|
test "diff options default indicators on and forward explicit false" {
  let defaults = DiffEditorOptions::default()
  assert_true(defaults.render_indicators)
  assert_true(defaults.internal().render_indicators)

  let disabled = defaults.with_render_indicators(false)
  assert_false(disabled.render_indicators)
  assert_false(disabled.internal().render_indicators)
}
