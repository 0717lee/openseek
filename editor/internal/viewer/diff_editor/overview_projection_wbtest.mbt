///|
test "overview rulers keep original and modified model coordinates separate" {
  let insert = @diff.DetailedLineRangeMapping(
    LineRange(1, 1),
    LineRange(1, 2),
    None,
  )
  let modify = @diff.DetailedLineRangeMapping(
    LineRange(2, 3),
    LineRange(2, 3),
    None,
  )
  let delete = @diff.DetailedLineRangeMapping(
    LineRange(4, 5),
    LineRange(4, 4),
    None,
  )
  let diff_state = DiffState::from_diff_result({
    changes: [insert, modify, delete],
    additional_alignments: [LineRangeMapping(LineRange(6, 6), LineRange(6, 7))],
  })

  assert_eq(original_diff_overview_ruler_entries(diff_state), [
    {
      id: 1,
      range: LineRange(2, 3),
      color: diff_overview_removed_color,
      lane: Full,
    },
    {
      id: 2,
      range: LineRange(4, 5),
      color: diff_overview_removed_color,
      lane: Full,
    },
  ])
  assert_eq(modified_diff_overview_ruler_entries(diff_state), [
    {
      id: 0,
      range: LineRange(1, 2),
      color: diff_overview_inserted_color,
      lane: Full,
    },
    {
      id: 1,
      range: LineRange(2, 3),
      color: diff_overview_inserted_color,
      lane: Full,
    },
  ])
}
