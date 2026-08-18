///|
test "diff presentation aligns insertions, deletions, and replacements" {
  let changes : Array[DiffLineChange] = [
    {
      original: LineRange(3, 3),
      modified: LineRange(3, 5),
      inner_changes: None,
    },
    {
      original: LineRange(8, 11),
      modified: LineRange(10, 10),
      inner_changes: None,
    },
    {
      original: LineRange(14, 16),
      modified: LineRange(13, 17),
      inner_changes: None,
    },
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
    {
      original: LineRange(1, 1),
      modified: LineRange(1, 3),
      inner_changes: None,
    },
  ]
  let presentation = diff_presentation(changes)
  assert_eq(presentation.original_spacers.length(), 1)
  assert_eq(presentation.original_spacers[0].after_line_number, 0)
  assert_eq(presentation.original_spacers[0].height_in_lines, 2)
}

///|
test "diff presentation separates non-empty character ranges by side" {
  let original = @base_common.Range(3, 5, 3, 8)
  let modified = @base_common.Range(3, 5, 3, 9)
  let inserted = @base_common.Range(4, 1, 4, 3)
  let presentation = diff_presentation([
    {
      original: LineRange(3, 5),
      modified: LineRange(3, 5),
      inner_changes: Some([(original, modified), (Range(4, 1, 4, 1), inserted)]),
    },
  ])
  assert_eq(presentation.original_inner_changed, [original])
  assert_eq(presentation.modified_inner_changed, [modified, inserted])
}

///|
test "unified deleted lines keep UTF-16 character intervals per row" {
  let ranges = [@base_common.Range(2, 3, 2, 6), Range(3, 5, 5, 3)]
  let first = deleted_inline_intervals_for_line(ranges, 2, 8)
  assert_eq(first.length(), 1)
  assert_eq(first[0].start_offset, 2)
  assert_eq(first[0].end_offset, 5)
  let middle = deleted_inline_intervals_for_line(ranges, 4, 7)
  assert_eq(middle.length(), 1)
  assert_eq(middle[0].start_offset, 0)
  assert_eq(middle[0].end_offset, 7)
  let ending = deleted_inline_intervals_for_line(ranges, 5, 6)
  assert_eq(ending.length(), 1)
  assert_eq(ending[0].start_offset, 0)
  assert_eq(ending[0].end_offset, 2)
}

///|
test "unified deleted zones precede replacement and deletion anchors" {
  assert_eq(
    unified_deleted_zone_anchor({
      original: LineRange(4, 6),
      modified: LineRange(4, 5),
      inner_changes: None,
    }),
    3,
  )
  assert_eq(
    unified_deleted_zone_anchor({
      original: LineRange(1, 3),
      modified: LineRange(1, 1),
      inner_changes: None,
    }),
    0,
  )
}

///|
test "unified deleted width follows tab stops and wide characters" {
  assert_eq(deleted_line_visual_columns("\t", 4), 4)
  assert_eq(deleted_line_visual_columns("a\tb", 4), 5)
  assert_eq(deleted_line_visual_columns("中🙂", 4), 4)
}
