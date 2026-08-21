///|
test "overview projection uses modified geometry and excludes alignments" {
  let insert = projection_change(1, 1, 1, 2)
  let modify = projection_change(2, 3, 2, 3)
  let delete = projection_change(4, 5, 4, 4)
  let projection = DiffFeatureProjection(
    {
      changes: [delete, insert, modify],
      additional_alignments: [
        LineRangeMapping(LineRange(3, 3), LineRange(3, 3)),
      ],
    },
    TextSnapshot("old\nchanged\nkeep\ndeleted"),
    TextSnapshot("new\nchanged\nkeep\ntail"),
  )
  let entries = diff_overview_ruler_entries(projection, 4)
  assert_eq(entries, [
    {
      id: 1,
      range: LineRange(2, 3),
      color: diff_overview_removed_color,
      lane: Left,
    },
    {
      id: 2,
      range: LineRange(4, 5),
      color: diff_overview_removed_color,
      lane: Left,
    },
    {
      id: 0,
      range: LineRange(1, 2),
      color: diff_overview_inserted_color,
      lane: Right,
    },
    {
      id: 1,
      range: LineRange(2, 3),
      color: diff_overview_inserted_color,
      lane: Right,
    },
  ])
}

///|
test "deletion-only overview anchors clamp to the modified model" {
  let before_start = projection_change(1, 2, 0, 0)
  let after_end = projection_change(8, 9, 9, 9)
  assert_eq(modified_overview_range(before_start, 4), LineRange(1, 2))
  assert_eq(modified_overview_range(after_end, 4), LineRange(4, 5))
}
