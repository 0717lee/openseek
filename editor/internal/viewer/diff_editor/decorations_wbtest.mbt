///|
test "inner diff decorations use VS Code className semantics" {
  let non_empty = inner_character_decoration(
    Range(2, 3, 2, 5),
    "diff-editor-char-delete",
    "diff-editor-original-character",
  )
  assert_eq(non_empty.options.class_name, "diff-editor-char-delete")
  assert_true(non_empty.options.inline_class_name is None)
  assert_true(non_empty.options.should_fill_line_on_line_break)

  let empty = inner_character_decoration(
    Range(2, 3, 2, 3),
    "diff-editor-char-insert",
    "diff-editor-modified-character",
  )
  assert_eq(
    empty.options.class_name,
    "diff-editor-char-insert diff-range-empty",
  )
  assert_true(empty.options.inline_class_name is None)
  assert_false(empty.options.should_fill_line_on_line_break)
}

///|
test "a changed empty model line still has an inclusive decoration range" {
  assert_eq(
    changed_line_range(LineRange(1, 2), TextSnapshot("")),
    Some(Range(1, 1, 1, 1)),
  )
  assert_true(changed_line_range(LineRange(1, 1), TextSnapshot("")) is None)
}

///|
test "render indicators only controls the narrow glyph lane" {
  let with_indicator = diff_whole_line_decorations(
      [Range(2, 1, 2, 4)],
      "diff-editor-line-delete",
      "delete-sign codicon codicon-diff-remove",
      "diff-editor-gutter-delete",
      true,
      "diff-editor-original-line",
    )[0].options
  assert_true(
    with_indicator.lines_decorations_class_name ==
    Some("delete-sign codicon codicon-diff-remove"),
  )
  assert_true(
    with_indicator.margin_class_name == Some("diff-editor-gutter-delete"),
  )
  assert_eq(with_indicator.class_name, "diff-editor-line-delete")

  let without_indicator = diff_whole_line_decorations(
      [Range(2, 1, 2, 4)],
      "diff-editor-line-delete",
      "delete-sign codicon codicon-diff-remove",
      "diff-editor-gutter-delete",
      false,
      "diff-editor-original-line",
    )[0].options
  assert_true(without_indicator.lines_decorations_class_name is None)
  assert_true(
    without_indicator.margin_class_name == Some("diff-editor-gutter-delete"),
  )
  assert_eq(without_indicator.class_name, "diff-editor-line-delete")
}
