///|
test "public hide unchanged options map into the internal coordinator" {
  let defaults = DiffEditorOptions::default()
  let defaults_internal = defaults.internal()
  assert_false(defaults.hide_unchanged_regions)
  assert_false(defaults_internal.hide_unchanged_regions)
  assert_eq(defaults_internal.hide_unchanged_regions_context_line_count, 3)
  assert_eq(defaults_internal.hide_unchanged_regions_minimum_line_count, 3)

  let enabled = DiffEditorOptions(
    hide_unchanged_regions_context_line_count=-1,
    hide_unchanged_regions_minimum_line_count=-2,
  ).with_hide_unchanged_regions(true)
  let enabled_internal = enabled.internal()
  assert_true(enabled.hide_unchanged_regions)
  assert_true(enabled_internal.hide_unchanged_regions)
  assert_eq(enabled_internal.hide_unchanged_regions_context_line_count, 0)
  assert_eq(enabled_internal.hide_unchanged_regions_minimum_line_count, 0)
}
