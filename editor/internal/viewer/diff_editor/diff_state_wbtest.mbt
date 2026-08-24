///|
fn diff_state_test_change(
  original_start : Int,
  original_end : Int,
  modified_start : Int,
  modified_end : Int,
) -> @diff.DetailedLineRangeMapping {
  DetailedLineRangeMapping(
    LineRange(original_start, original_end),
    LineRange(modified_start, modified_end),
    None,
  )
}

///|
test "DiffState preserves canonical provider order and cycles navigation" {
  let first = diff_state_test_change(1, 1, 1, 2)
  let second = diff_state_test_change(3, 4, 4, 5)
  let state = DiffState::from_diff_result({
    changes: [first, second],
    additional_alignments: [],
  })
  assert_eq(state.mapping_at(0), Some(first))
  assert_eq(state.mapping_at(1), Some(second))
  assert_eq(state.next_change(None).unwrap().change_index, 0)
  assert_eq(state.next_change(Some(1)).unwrap().change_index, 0)
  assert_eq(state.previous_change(None).unwrap().change_index, 1)
  assert_eq(state.previous_change(Some(0)).unwrap().change_index, 1)
}

///|
test "additional alignments enter geometry only" {
  let change = diff_state_test_change(1, 2, 1, 2)
  let additional = @diff.LineRangeMapping(LineRange(3, 3), LineRange(3, 4))
  let state = DiffState::from_diff_result({
    changes: [change],
    additional_alignments: [additional],
  })
  assert_eq(state.mapping_count(), 1)
  assert_eq(state.alignments().length(), 2)
  assert_eq(state.alignments()[0].diff, Some(change))
  assert_eq(state.alignments()[1].line_range_mapping, additional)
  assert_true(state.alignments()[1].diff is None)
}
