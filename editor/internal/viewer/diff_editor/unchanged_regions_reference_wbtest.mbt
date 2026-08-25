// Behavior port from VS Code 07c20d96cf3f2cbc8142ac7079ba9048cf7f6134:
// - src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts
//   (`UnchangedRegion.fromDiffs`)
// - src/vs/editor/test/browser/widget/diffEditorWidget.test.ts
// Local adaptation: an empty diff keeps an identical document fully visible.

///|
fn unchanged_region_change(
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
fn reference_hidden_regions(
  changes : Array[@diff.DetailedLineRangeMapping],
  original_line_count : Int,
  modified_line_count : Int,
) -> Array[@diff.LineRangeMapping] {
  project_hidden_unchanged_regions(
    changes, original_line_count, modified_line_count, 3, 3,
  )
}

///|
test "hide unchanged defaults match pinned VS Code" {
  let defaults = DiffEditorOptions::default()
  assert_false(defaults.hide_unchanged_regions)
  assert_eq(defaults.hide_unchanged_regions_context_line_count, 3)
  assert_eq(defaults.hide_unchanged_regions_minimum_line_count, 3)

  let clamped = DiffEditorOptions(
    hide_unchanged_regions=true,
    hide_unchanged_regions_context_line_count=-1,
    hide_unchanged_regions_minimum_line_count=-2,
  )
  assert_true(clamped.hide_unchanged_regions)
  assert_eq(clamped.hide_unchanged_regions_context_line_count, 0)
  assert_eq(clamped.hide_unchanged_regions_minimum_line_count, 0)
}

///|
test "everything changed has no hidden unchanged region" {
  assert_true(
    reference_hidden_regions([unchanged_region_change(1, 10, 1, 10)], 10, 10).is_empty(),
  )
}

///|
/// Upstream's `Nothing changed` case hides `[1,11)` on both sides. The local
/// product contract keeps an identical document visible instead of presenting
/// an empty comparison surface.
test "identical empty diff remains fully visible by local contract" {
  assert_true(reference_hidden_regions([], 10, 10).is_empty())
}

///|
test "change in the middle hides leading and trailing gaps with context" {
  assert_eq(
    reference_hidden_regions(
      [unchanged_region_change(50, 60, 50, 60)],
      100,
      100,
    ),
    [
      LineRangeMapping(LineRange(1, 47), LineRange(1, 47)),
      LineRangeMapping(LineRange(63, 101), LineRange(63, 101)),
    ],
  )
}

///|
test "change at the end keeps leading context arithmetic from upstream" {
  assert_eq(
    reference_hidden_regions(
      [unchanged_region_change(99, 100, 100, 100)],
      100,
      100,
    ),
    [LineRangeMapping(LineRange(1, 96), LineRange(1, 96))],
  )
}

///|
test "middle gap keeps context on both sides" {
  assert_eq(
    reference_hidden_regions(
      [
        unchanged_region_change(1, 10, 1, 10),
        unchanged_region_change(91, 101, 91, 101),
      ],
      100,
      100,
    ),
    [LineRangeMapping(LineRange(13, 88), LineRange(13, 88))],
  )
}

///|
test "minimum hidden threshold is inclusive for edge and middle gaps" {
  assert_eq(
    reference_hidden_regions([unchanged_region_change(7, 11, 7, 11)], 10, 10),
    [LineRangeMapping(LineRange(1, 4), LineRange(1, 4))],
  )
  assert_eq(
    reference_hidden_regions(
      [
        unchanged_region_change(1, 6, 1, 6),
        unchanged_region_change(15, 21, 15, 21),
      ],
      20,
      20,
    ),
    [LineRangeMapping(LineRange(9, 12), LineRange(9, 12))],
  )
  assert_true(
    reference_hidden_regions(
      [
        unchanged_region_change(1, 6, 1, 6),
        unchanged_region_change(14, 21, 14, 21),
      ],
      20,
      20,
    ).is_empty(),
  )
}
