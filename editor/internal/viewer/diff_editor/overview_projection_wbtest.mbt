///|
test "overview projection uses modified geometry and excludes alignments" {
  let insert = projection_change(1, 1, 1, 2)
  let modify = projection_change(2, 3, 2, 3)
  let delete = projection_change(4, 5, 4, 4)
  let projection = DiffFeatureProjection(
    {
      changes: [delete, insert, modify],
      additional_alignments: [
        @diff.LineRangeMapping(
          @base_common.LineRange(3, 3),
          @base_common.LineRange(3, 3),
        ),
      ],
    },
    @model.TextSnapshot("old\nchanged\nkeep\ndeleted"),
    @model.TextSnapshot("new\nchanged\nkeep\ntail"),
  )
  let entries = diff_overview_ruler_entries(projection, 4)
  assert_eq(entries, [
    {
      id: 1,
      range: @base_common.LineRange(2, 3),
      color: diff_overview_removed_color,
      lane: Left,
    },
    {
      id: 2,
      range: @base_common.LineRange(4, 5),
      color: diff_overview_removed_color,
      lane: Left,
    },
    {
      id: 0,
      range: @base_common.LineRange(1, 2),
      color: diff_overview_inserted_color,
      lane: Right,
    },
    {
      id: 1,
      range: @base_common.LineRange(2, 3),
      color: diff_overview_inserted_color,
      lane: Right,
    },
  ])
}

///|
test "deletion-only overview anchors clamp to the modified model" {
  let before_start = projection_change(1, 2, 0, 0)
  let after_end = projection_change(8, 9, 9, 9)
  assert_eq(
    modified_overview_range(before_start, 4),
    @base_common.LineRange(1, 2),
  )
  assert_eq(modified_overview_range(after_end, 4), @base_common.LineRange(4, 5))
}
