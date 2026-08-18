///|
test "changes_to_decorations maps the three change types (quickDiffDecorator.ts:140)" {
  let added = compute_changes(["1", "4"], ["1", "2", "3", "4"])[0]
  let modified = compute_changes(["1", "2", "3", "4", "old"], [
      "1", "2", "3", "4", "new",
    ])[0]
  let deleted = compute_changes(
      ["1", "2", "3", "4", "5", "6", "old 1", "old 2"],
      ["1", "2", "3", "4", "5", "6"],
    )[0]
  let decorations = changes_to_decorations([added, modified, deleted])
  assert_eq(decorations.length(), 3)

  // Add: whole-line, columns 1..1 over the modified span.
  assert_eq(decorations[0].range.to_string(), "[2,1 -> 3,1]")
  assert_eq(
    decorations[0].options.lines_decorations_class_name.unwrap(),
    "dirty-diff-glyph dirty-diff-added primary",
  )
  assert_true(decorations[0].options.is_whole_line)

  // Modify.
  assert_eq(decorations[1].range.to_string(), "[5,1 -> 5,1]")
  assert_eq(
    decorations[1].options.lines_decorations_class_name.unwrap(),
    "dirty-diff-glyph dirty-diff-modified primary",
  )
  assert_true(decorations[1].options.is_whole_line)

  // Delete: zero-width marker pinned at MAX_VALUE column of the line the
  // deleted block follows; not whole-line.
  assert_eq(
    decorations[2].range.to_string(),
    "[6,\{MAX_COLUMN} -> 6,\{MAX_COLUMN}]",
  )
  assert_eq(
    decorations[2].options.lines_decorations_class_name.unwrap(),
    "dirty-diff-glyph dirty-diff-deleted primary",
  )
  assert_false(decorations[2].options.is_whole_line)
}
