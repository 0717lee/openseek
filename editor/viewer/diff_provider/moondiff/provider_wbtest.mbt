///|
fn changed_line(
  index : Int,
  prefix : String,
  changed : String,
  suffix : String,
) -> @mbtdiff.DiffLine {
  {
    index,
    segments: [
      { kind: Unchanged, text: prefix, },
      { kind: Changed, text: changed, },
      { kind: Unchanged, text: suffix, },
    ],
  }
}

///|
test "fragment adapter keeps MoonDiff coordinates local to one section" {
  let document : @mbtdiff.HunkDocument = {
    hunks: [
      {
        old_start: 0,
        old_len: 1,
        new_start: 0,
        new_len: 1,
        blocks: [
          ChangeBlock([
            Paired(
              changed_line(0, "fn value() { ", "1", " }"),
              changed_line(0, "fn value() { ", "2", " }"),
            ),
          ]),
        ],
      },
    ],
  }
  guard fragment_document_diff(document, "fn value() { 1 }", "fn value() { 2 }")
    is Some({ changes: [change], additional_alignments: [], }) else {
    fail("expected one valid fragment-local change")
  }
  assert_eq(change.original, LineRange(1, 2))
  assert_eq(change.modified, LineRange(1, 2))
  guard change.inner_changes is Some([inner]) else {
    fail("expected one intraline mapping")
  }
  assert_eq(inner.original, Range(1, 14, 1, 15))
  assert_eq(inner.modified, Range(1, 14, 1, 15))
}

///|
test "fragment adapter preserves one-sided intraline mappings" {
  let document : @mbtdiff.HunkDocument = {
    hunks: [
      {
        old_start: 0,
        old_len: 0,
        new_start: 0,
        new_len: 1,
        blocks: [ChangeBlock([NewOnly(changed_line(0, "", "new()", ""))])],
      },
    ],
  }
  guard fragment_document_diff(document, "anchor", "new()\nanchor")
    is Some({ changes: [change], additional_alignments: [], }) else {
    fail("expected one insertion")
  }
  assert_eq(change.original, LineRange(1, 1))
  assert_eq(change.modified, LineRange(1, 2))
  guard change.inner_changes is Some([inner]) else {
    fail("expected the inserted token mapping")
  }
  assert_eq(inner.original, Range(1, 1, 1, 1))
  assert_eq(inner.modified, Range(1, 1, 1, 6))
}

///|
test "ignored fragment rows do not become visible changes" {
  let old : @mbtdiff.DiffLine = {
    index: 0,
    segments: [{ kind: Changed, text: "// old", }],
  }
  let new : @mbtdiff.DiffLine = {
    index: 0,
    segments: [{ kind: Changed, text: "// new", }],
  }
  let document : @mbtdiff.HunkDocument = {
    hunks: [
      {
        old_start: 0,
        old_len: 1,
        new_start: 0,
        new_len: 1,
        blocks: [IgnoredBlock([Paired(old, new)])],
      },
    ],
  }
  guard fragment_document_diff(document, "// old", "// new") is Some(result) else {
    fail("expected a valid ignored fragment")
  }
  assert_true(result.changes.is_empty())
  assert_true(result.additional_alignments.is_empty())
}

///|
test "fragment provider returns its prevalidated document unchanged" {
  let document : @diff.DocumentDiff = {
    changes: [],
    additional_alignments: [],
  }
  let provider = MoonFragmentDiffProvider(document)
  let object = provider.as_document_diff_provider()
  assert_eq(
    object.compute_diff(TextSnapshot("old"), TextSnapshot("new"), {
      ignore_trim_whitespace: true,
    }),
    document,
  )
}
