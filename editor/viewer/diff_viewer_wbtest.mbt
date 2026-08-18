///|
test "diff presentation aligns insertions, deletions, and replacements" {
  let changes : Array[DiffLineChange] = [
    {
      original: LineRange(3, 3),
      modified: LineRange(3, 5),
      original_inner_changed: [],
      modified_inner_changed: [],
    },
    {
      original: LineRange(8, 11),
      modified: LineRange(10, 10),
      original_inner_changed: [],
      modified_inner_changed: [],
    },
    {
      original: LineRange(14, 16),
      modified: LineRange(13, 17),
      original_inner_changed: [],
      modified_inner_changed: [],
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
      original_inner_changed: [],
      modified_inner_changed: [],
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
      original_inner_changed: [original, Range(4, 1, 4, 1)],
      modified_inner_changed: [modified, inserted],
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
      original_inner_changed: [],
      modified_inner_changed: [],
    }),
    3,
  )
  assert_eq(
    unified_deleted_zone_anchor({
      original: LineRange(1, 3),
      modified: LineRange(1, 1),
      original_inner_changed: [],
      modified_inner_changed: [],
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

///|
test "token diff adapts moondiff token segments to Viewer ranges" {
  let original = "fn answer() { 1 }"
  let modified = "fn answer() { 2 }"
  let calculation = calculate_diff_changes(
    TokenDiff,
    true,
    [original],
    [modified],
    original,
    modified,
  )
  assert_true(calculation.effective_mode is TokenDiff)
  assert_false(calculation.fell_back)
  guard calculation.changes is [change] else {
    fail("expected one aligned token change")
  }
  assert_eq(change.original, LineRange(1, 2))
  assert_eq(change.modified, LineRange(1, 2))
  assert_eq(change.original_inner_changed, [Range(1, 15, 1, 16)])
  assert_eq(change.modified_inner_changed, [Range(1, 15, 1, 16)])
}

///|
test "token diff ranges remain UTF-16 after a surrogate pair" {
  let original = "fn answer() { \"😀\"; 1 }"
  let modified = "fn answer() { \"😀\"; 2 }"
  let calculation = calculate_diff_changes(
    TokenDiff,
    true,
    [original],
    [modified],
    original,
    modified,
  )
  guard calculation.changes is [change] else {
    fail("expected one aligned token change")
  }
  assert_eq(change.original_inner_changed, [Range(1, 21, 1, 22)])
  assert_eq(change.modified_inner_changed, [Range(1, 21, 1, 22)])
}

///|
test "tree diff uses structural moondiff output without fallback" {
  let original = "fn answer() { old_value() }"
  let modified = "fn answer() { new_value() }"
  let calculation = calculate_diff_changes(
    TreeDiff,
    true,
    [original],
    [modified],
    original,
    modified,
  )
  assert_true(calculation.effective_mode is TreeDiff)
  assert_false(calculation.fell_back)
  assert_false(calculation.changes.is_empty())
  let presentation = diff_presentation(calculation.changes)
  assert_eq(presentation.original_changed, [LineRange(1, 2)])
  assert_eq(presentation.modified_changed, [LineRange(1, 2)])
  assert_false(presentation.original_inner_changed.is_empty())
  assert_false(presentation.modified_inner_changed.is_empty())
}

///|
test "tree parse failure falls back to the standard editor diff" {
  let original = "fn broken( {"
  let modified = "fn okay() {}"
  let calculation = calculate_diff_changes(
    TreeDiff,
    true,
    [original],
    [modified],
    original,
    modified,
  )
  assert_true(calculation.effective_mode is StandardDiff)
  assert_true(calculation.fell_back)
  assert_false(calculation.changes.is_empty())
}

///|
test "invalid token document is rejected at the standard fallback boundary" {
  let invalid : @tokdiff.DiffDocument = {
    hunks: [
      {
        old_start: 0,
        old_len: 1,
        new_start: 0,
        new_len: 0,
        blocks: [
          @tokdiff.DiffBlock::ChangeBlock([
            @tokdiff.DiffRow::OldOnly({
              index: 4,
              segments: [
                { kind: @tokdiff.DiffSegmentKind::Changed, text: "old" },
              ],
            }),
          ]),
        ],
      },
    ],
  }
  assert_true(moondiff_document_changes(invalid, ["old"], []) is None)
}

///|
test "moondiff controls are limited to exact mbt paths" {
  fn model(path : String) -> @model.TextModel {
    @model.TextModel(
      try! @base_common.Uri::from(scheme="memory", path~),
      path,
      "moonbit",
      1,
      "test",
      "fn main {}",
    )
  }
  let original = model("/main.mbt")
  let source = model("/MAIN.MBT")
  assert_true(DiffEditorModel(original, source).supports_moondiff())
  let interface = model("/pkg.generated.mbti")
  assert_false(DiffEditorModel(original, interface).supports_moondiff())
  let markdown = model("/README.mbt.md")
  assert_false(DiffEditorModel(original, markdown).supports_moondiff())
  original.dispose()
  source.dispose()
  interface.dispose()
  markdown.dispose()
}
