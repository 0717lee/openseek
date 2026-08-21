///|
fn alignment_test_text(line_count : Int) -> String {
  let lines : Array[String] = []
  for _index in 0..<line_count {
    lines.push("line")
  }
  lines.join("\n")
}

///|
fn alignment_test_projection(
  changes : Array[@diff.DetailedLineRangeMapping],
  additional_alignments : Array[@diff.LineRangeMapping],
  original_line_count : Int,
  modified_line_count : Int,
) -> DiffFeatureProjection {
  DiffFeatureProjection(
    { changes, additional_alignments },
    @model.TextSnapshot(alignment_test_text(original_line_count)),
    @model.TextSnapshot(alignment_test_text(modified_line_count)),
  )
}

///|
fn alignment_test_change(
  original_start : Int,
  original_end : Int,
  modified_start : Int,
  modified_end : Int,
  inner_changes? : Array[@diff.RangeMapping],
) -> @diff.DetailedLineRangeMapping {
  @diff.DetailedLineRangeMapping(
    @base_common.LineRange(original_start, original_end),
    @base_common.LineRange(modified_start, modified_end),
    inner_changes,
  )
}

///|
test "geometry alignment handles unequal insert delete and replace hunks" {
  let projection = alignment_test_projection(
    [
      alignment_test_change(3, 3, 3, 5),
      alignment_test_change(8, 11, 10, 10),
      alignment_test_change(14, 16, 13, 17),
    ],
    [],
    16,
    17,
  )
  let spacers = compute_managed_alignment_spacers(
    projection,
    PaneGeometrySnapshot(16, 20.0),
    PaneGeometrySnapshot(17, 20.0),
  )
  assert_eq(spacers.original(), [
    { after_line_number: 2, height_in_px: 40.0 },
    { after_line_number: 15, height_in_px: 40.0 },
  ])
  assert_eq(spacers.modified(), [{ after_line_number: 9, height_in_px: 60.0 }])
}

///|
test "wrapped model lines align from exact per-line pixel heights" {
  let projection = alignment_test_projection([], [], 4, 4)
  let spacers = compute_managed_alignment_spacers(
    projection,
    PaneGeometrySnapshot(4, 20.0, model_line_heights=[
      { line_number: 2, height_in_px: 40.0 },
    ]),
    PaneGeometrySnapshot(4, 20.0),
  )
  assert_true(spacers.original().is_empty())
  assert_eq(spacers.modified(), [{ after_line_number: 2, height_in_px: 20.0 }])
}

///|
test "foreign zones align unchanged regions at their model boundaries" {
  let projection = alignment_test_projection([], [], 10, 10)
  let spacers = compute_managed_alignment_spacers(
    projection,
    PaneGeometrySnapshot(10, 20.0, foreign_zone_heights=[
      { after_line_number: 3, height_in_px: 30.0 },
      { after_line_number: 8, height_in_px: 5.0 },
    ]),
    PaneGeometrySnapshot(10, 20.0, foreign_zone_heights=[
      { after_line_number: 3, height_in_px: 10.0 },
      { after_line_number: 6, height_in_px: 25.0 },
    ]),
  )
  assert_eq(spacers.original(), [{ after_line_number: 6, height_in_px: 25.0 }])
  assert_eq(spacers.modified(), [
    { after_line_number: 3, height_in_px: 20.0 },
    { after_line_number: 8, height_in_px: 5.0 },
  ])
}

///|
test "hidden lines and replacement foreign zones both affect geometry" {
  let projection = alignment_test_projection([], [], 4, 4)
  let hidden_only = compute_managed_alignment_spacers(
    projection,
    PaneGeometrySnapshot(4, 20.0, hidden_lines=[@base_common.LineRange(2, 3)]),
    PaneGeometrySnapshot(4, 20.0),
  )
  assert_eq(hidden_only.original(), [
    { after_line_number: 2, height_in_px: 20.0 },
  ])
  assert_true(hidden_only.modified().is_empty())

  let hidden_with_zone = compute_managed_alignment_spacers(
    projection,
    PaneGeometrySnapshot(4, 20.0, hidden_lines=[@base_common.LineRange(2, 3)], foreign_zone_heights=[
      { after_line_number: 2, height_in_px: 50.0 },
    ]),
    PaneGeometrySnapshot(4, 20.0),
  )
  assert_true(hidden_with_zone.original().is_empty())
  assert_eq(hidden_with_zone.modified(), [
    { after_line_number: 2, height_in_px: 30.0 },
  ])
}

///|
test "additional alignment can align omitted geometry without a real change" {
  let additional = @diff.LineRangeMapping(
    @base_common.LineRange(2, 2),
    @base_common.LineRange(2, 3),
  )
  let projection = alignment_test_projection([], [additional], 3, 4)
  assert_eq(projection.change_count(), 0)
  let spacers = compute_managed_alignment_spacers(
    projection,
    PaneGeometrySnapshot(3, 20.0),
    PaneGeometrySnapshot(4, 20.0),
  )
  assert_eq(spacers.original(), [{ after_line_number: 1, height_in_px: 20.0 }])
  assert_true(spacers.modified().is_empty())
}

///|
test "character mappings add synchronization points inside a real hunk" {
  let original_inner = @base_common.Range(2, 5, 3, 4)
  let modified_inner = @base_common.Range(2, 5, 4, 4)
  let change = alignment_test_change(2, 6, 2, 8, inner_changes=[
    @diff.RangeMapping(original_inner, modified_inner),
  ])
  let projection = alignment_test_projection([change], [], 7, 9)
  let spacers = compute_managed_alignment_spacers(
    projection,
    PaneGeometrySnapshot(7, 20.0, line_max_columns=Array::make(7, 100)),
    PaneGeometrySnapshot(9, 20.0),
  )
  assert_eq(spacers.original(), [
    { after_line_number: 2, height_in_px: 20.0 },
    { after_line_number: 5, height_in_px: 20.0 },
  ])
  assert_true(spacers.modified().is_empty())
}

///|
test "final-line geometry is an ordinary boundary not a tail correction" {
  let projection = alignment_test_projection([], [], 3, 3)
  let original = PaneGeometrySnapshot(
    3,
    20.0,
    model_line_heights=[{ line_number: 3, height_in_px: 60.0 }],
    foreign_zone_heights=[{ after_line_number: 3, height_in_px: 10.0 }],
  )
  let modified = PaneGeometrySnapshot(3, 20.0)
  let spacers = compute_managed_alignment_spacers(
    projection, original, modified,
  )
  assert_true(spacers.original().is_empty())
  assert_eq(spacers.modified(), [{ after_line_number: 3, height_in_px: 50.0 }])
  assert_eq(
    original.content_height(),
    modified.content_height() + spacers.modified()[0].height_in_px,
  )
}

///|
test "snapshot normalizes duplicate foreign zones and excludes invalid input" {
  let geometry = PaneGeometrySnapshot(3, 20.0, foreign_zone_heights=[
    { after_line_number: 0, height_in_px: 7.0 },
    { after_line_number: 2, height_in_px: 8.0 },
    { after_line_number: 2, height_in_px: 12.0 },
    { after_line_number: 4, height_in_px: 99.0 },
    { after_line_number: 1, height_in_px: -3.0 },
  ])
  assert_eq(geometry.foreign_zone_heights(), [
    { after_line_number: 0, height_in_px: 7.0 },
    { after_line_number: 2, height_in_px: 20.0 },
  ])
  assert_eq(geometry.content_height(), 87.0)
}
