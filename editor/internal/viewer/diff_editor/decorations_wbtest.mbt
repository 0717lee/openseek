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
