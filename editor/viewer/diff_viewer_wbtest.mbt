///|
test "diff presentation aligns insertions, deletions, and replacements" {
  let changes : Array[DiffLineChange] = [
    { original: LineRange(3, 3), modified: LineRange(3, 5) },
    { original: LineRange(8, 11), modified: LineRange(10, 10) },
    { original: LineRange(14, 16), modified: LineRange(13, 17) },
  ]
  let presentation = diff_presentation(changes)
  assert_eq(presentation.original_changed, [LineRange(8, 11), LineRange(14, 16)])
  assert_eq(presentation.modified_changed, [LineRange(3, 5), LineRange(13, 17)])
  assert_eq(presentation.original_spacers.length(), 2)
  assert_eq(presentation.original_spacers[0].after_line_number, 2)
  assert_eq(presentation.original_spacers[0].height_in_lines, 2)
  assert_eq(presentation.original_spacers[1].after_line_number, 15)
  assert_eq(presentation.original_spacers[1].height_in_lines, 2)
  assert_eq(presentation.modified_spacers.length(), 1)
  assert_eq(presentation.modified_spacers[0].after_line_number, 9)
  assert_eq(presentation.modified_spacers[0].height_in_lines, 3)
}

///|
test "diff presentation supports a spacer before the first line" {
  let changes : Array[DiffLineChange] = [
    { original: LineRange(1, 1), modified: LineRange(1, 3) },
  ]
  let presentation = diff_presentation(changes)
  assert_eq(presentation.original_spacers.length(), 1)
  assert_eq(presentation.original_spacers[0].after_line_number, 0)
  assert_eq(presentation.original_spacers[0].height_in_lines, 2)
}
