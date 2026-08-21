///|
fn projection_change(
  original_start : Int,
  original_end : Int,
  modified_start : Int,
  modified_end : Int,
  inner_changes? : Array[@diff.RangeMapping],
) -> @diff.DetailedLineRangeMapping {
  DetailedLineRangeMapping(
    LineRange(original_start, original_end),
    LineRange(modified_start, modified_end),
    inner_changes,
  )
}

///|
test "additional alignments are isolated to geometry anchors" {
  let change = projection_change(1, 2, 1, 2)
  let extra = @diff.LineRangeMapping(LineRange(2, 2), LineRange(2, 2))
  let original = @model.TextSnapshot("before\ntail")
  let modified = @model.TextSnapshot("after\ntail")
  let without_extra = DiffFeatureProjection(
    { changes: [change], additional_alignments: [] },
    original,
    modified,
  )
  let with_extra = DiffFeatureProjection(
    { changes: [change], additional_alignments: [extra] },
    original,
    modified,
  )

  assert_eq(
    with_extra.original_decorations().whole_line_ranges(),
    without_extra.original_decorations().whole_line_ranges(),
  )
  assert_eq(
    with_extra.modified_decorations().whole_line_ranges(),
    without_extra.modified_decorations().whole_line_ranges(),
  )
  assert_eq(
    with_extra.original_decorations().inner_ranges(),
    without_extra.original_decorations().inner_ranges(),
  )
  assert_eq(
    with_extra.modified_decorations().inner_ranges(),
    without_extra.modified_decorations().inner_ranges(),
  )
  assert_eq(
    with_extra.original_overview_entries(),
    without_extra.original_overview_entries(),
  )
  assert_eq(
    with_extra.modified_overview_entries(),
    without_extra.modified_overview_entries(),
  )
  assert_eq(with_extra.change_count(), 1)
  assert_eq(with_extra.next_change(None), without_extra.next_change(None))
  assert_eq(with_extra.alignment_anchors(), [change.line_mapping(), extra])
  assert_eq(without_extra.alignment_anchors(), [change.line_mapping()])
}

///|
test "insert delete and modify project pane-specific decorations" {
  let insert = projection_change(1, 1, 1, 2)
  let original_inner = @base_common.Range(2, 2, 2, 4)
  let modified_inner = @base_common.Range(2, 2, 2, 4)
  let modify = projection_change(2, 3, 2, 3, inner_changes=[
    RangeMapping(original_inner, modified_inner),
  ])
  let delete = projection_change(3, 4, 4, 4)
  // Deliberately unsorted: projection order is independent of provider array
  // order, and navigation/overview indices use the sorted canonical changes.
  let projection = DiffFeatureProjection(
    { changes: [delete, insert, modify], additional_alignments: [] },
    TextSnapshot("keep\na😀b\ngone\ntail"),
    TextSnapshot("new\naXYb\nkeep\ntail"),
  )

  // The emoji occupies two UTF-16 code units, so line 2's max column is 5.
  assert_eq(projection.original_decorations().whole_line_ranges(), [
    Range(2, 1, 2, 5),
    Range(3, 1, 3, 5),
  ])
  assert_eq(projection.modified_decorations().whole_line_ranges(), [
    Range(1, 1, 1, 4),
    Range(2, 1, 2, 5),
  ])
  assert_eq(projection.original_decorations().inner_ranges(), [original_inner])
  assert_eq(projection.modified_decorations().inner_ranges(), [modified_inner])

  // Empty original/modified ranges remain alignment anchors but never create
  // phantom whole-line or overview decorations on that pane.
  assert_eq(projection.original_overview_entries(), [
    { change_index: 1, range: LineRange(2, 3) },
    { change_index: 2, range: LineRange(3, 4) },
  ])
  assert_eq(projection.modified_overview_entries(), [
    { change_index: 0, range: LineRange(1, 2) },
    { change_index: 1, range: LineRange(2, 3) },
  ])
  assert_eq(projection.alignment_anchors(), [
    insert.line_mapping(),
    modify.line_mapping(),
    delete.line_mapping(),
  ])
  // Provider UTF-16 columns are copied exactly rather than converted through
  // Unicode scalar values or bytes.
  assert_eq(projection.change_at(1), Some(modify))
  assert_eq(
    projection.change_at(1).unwrap().inner_changes.unwrap()[0].original,
    Range(2, 2, 2, 4),
  )
}

///|
test "navigation follows sorted changes and cycles in both directions" {
  let first = projection_change(1, 1, 1, 2)
  let second = projection_change(2, 3, 2, 3)
  let third = projection_change(4, 5, 4, 4)
  let projection = DiffFeatureProjection(
    { changes: [third, second, first], additional_alignments: [] },
    TextSnapshot("one\ntwo\nthree\nfour"),
    TextSnapshot("added\ntwo\nthree\nfour"),
  )

  assert_eq(projection.change_at(0), Some(first))
  assert_eq(projection.change_at(1), Some(second))
  assert_eq(projection.change_at(2), Some(third))
  assert_true(projection.change_at(-1) is None)
  assert_true(projection.change_at(3) is None)

  let next_first = projection.next_change(None).unwrap()
  assert_eq(next_first.change_index, 0)
  assert_eq(next_first.change_count, 3)
  assert_eq(next_first.change, first)
  assert_eq(projection.next_change(Some(0)).unwrap().change_index, 1)
  assert_eq(projection.next_change(Some(1)).unwrap().change_index, 2)
  assert_eq(projection.next_change(Some(2)).unwrap().change_index, 0)
  assert_eq(projection.next_change(Some(99)).unwrap().change_index, 0)

  assert_eq(projection.previous_change(None).unwrap().change_index, 2)
  assert_eq(projection.previous_change(Some(2)).unwrap().change_index, 1)
  assert_eq(projection.previous_change(Some(1)).unwrap().change_index, 0)
  assert_eq(projection.previous_change(Some(0)).unwrap().change_index, 2)
  assert_eq(projection.previous_change(Some(-1)).unwrap().change_index, 2)
}

///|
test "empty projection has no feature output or navigation target" {
  let projection = DiffFeatureProjection(
    { changes: [], additional_alignments: [] },
    TextSnapshot(""),
    TextSnapshot(""),
  )
  assert_eq(projection.change_count(), 0)
  assert_true(projection.original_decorations().whole_line_ranges().is_empty())
  assert_true(projection.modified_decorations().whole_line_ranges().is_empty())
  assert_true(projection.original_overview_entries().is_empty())
  assert_true(projection.modified_overview_entries().is_empty())
  assert_true(projection.alignment_anchors().is_empty())
  assert_true(projection.next_change(None) is None)
  assert_true(projection.previous_change(None) is None)
}
