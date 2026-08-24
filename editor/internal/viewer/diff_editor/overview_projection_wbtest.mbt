///|
test "overview rulers keep original and modified model coordinates separate" {
  let insert = @diff.DetailedLineRangeMapping(
    @base_common.LineRange(1, 1),
    @base_common.LineRange(1, 2),
    None,
  )
  let modify = @diff.DetailedLineRangeMapping(
    @base_common.LineRange(2, 3),
    @base_common.LineRange(2, 3),
    None,
  )
  let delete = @diff.DetailedLineRangeMapping(
    @base_common.LineRange(4, 5),
    @base_common.LineRange(4, 4),
    None,
  )
  let diff_state = DiffState::from_diff_result({
    changes: [insert, modify, delete],
    additional_alignments: [
      @diff.LineRangeMapping(
        @base_common.LineRange(6, 6),
        @base_common.LineRange(6, 7),
      ),
    ],
  })

  assert_eq(original_diff_overview_ruler_entries(diff_state), [
    {
      id: 1,
      range: @base_common.LineRange(2, 3),
      color: diff_overview_removed_color,
      lane: @code_widget.Full,
    },
    {
      id: 2,
      range: @base_common.LineRange(4, 5),
      color: diff_overview_removed_color,
      lane: @code_widget.Full,
    },
  ])
  assert_eq(modified_diff_overview_ruler_entries(diff_state), [
    {
      id: 0,
      range: @base_common.LineRange(1, 2),
      color: diff_overview_inserted_color,
      lane: @code_widget.Full,
    },
    {
      id: 1,
      range: @base_common.LineRange(2, 3),
      color: diff_overview_inserted_color,
      lane: @code_widget.Full,
    },
  ])
}
