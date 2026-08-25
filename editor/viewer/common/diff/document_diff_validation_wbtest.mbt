///|
test "document diff validation canonicalizes newline anchors idempotently" {
  let original = @model.TextSnapshot("deleted\n\nkeep")
  let modified = @model.TextSnapshot("\nkeep")
  let raw : DocumentDiff = {
    changes: [
      DetailedLineRangeMapping(
        LineRange(1, 2),
        LineRange(1, 1),
        Some([RangeMapping(Range(1, 1, 1, 8), Range(1, 1, 1, 1))]),
      ),
    ],
    additional_alignments: [],
  }
  guard normalize_and_validate_document_diff(raw, original, modified)
    is Some(canonical) else {
    fail("expected canonical pure-deletion mapping")
  }
  guard canonical.changes[0].inner_changes is Some([inner]) else {
    fail("expected one canonical inner mapping")
  }
  assert_eq(inner.original, Range(1, 1, 2, 1))
  assert_eq(inner.modified, Range(1, 1, 2, 1))
  assert_eq(
    normalize_and_validate_document_diff(canonical, original, modified),
    Some(canonical),
  )
}

///|
test "document diff validation rejects overlapping changes and alignments" {
  let original = @model.TextSnapshot("fn stable() {}")
  let modified = @model.TextSnapshot(
    "/// ignored before\nfn inserted() {}\n/// ignored after\nfn stable() {}",
  )
  let invalid : DocumentDiff = {
    changes: [DetailedLineRangeMapping(LineRange(1, 1), LineRange(2, 3), None)],
    additional_alignments: [LineRangeMapping(LineRange(1, 1), LineRange(1, 4))],
  }
  assert_true(
    normalize_and_validate_document_diff(invalid, original, modified) is None,
  )
}

///|
test "document diff validation accepts separated ignored-row alignments" {
  let original = @model.TextSnapshot("fn stable() {}")
  let modified = @model.TextSnapshot(
    "/// ignored before\nfn inserted() {}\n/// ignored after\nfn stable() {}",
  )
  let valid : DocumentDiff = {
    changes: [DetailedLineRangeMapping(LineRange(1, 1), LineRange(2, 3), None)],
    additional_alignments: [
      LineRangeMapping(LineRange(1, 1), LineRange(1, 2)),
      LineRangeMapping(LineRange(1, 1), LineRange(3, 4)),
    ],
  }
  assert_eq(
    normalize_and_validate_document_diff(valid, original, modified),
    Some(valid),
  )
}

///|
test "document diff validation rejects invalid provider coordinates" {
  let original = @model.TextSnapshot("old\nkeep")
  let modified = @model.TextSnapshot("new\nkeep")
  let invalid : DocumentDiff = {
    changes: [
      DetailedLineRangeMapping(
        LineRange(1, 2),
        LineRange(1, 2),
        Some([RangeMapping(Range(1, 1, 99, 1), Range(1, 1, 99, 1))]),
      ),
    ],
    additional_alignments: [],
  }
  assert_true(
    normalize_and_validate_document_diff(invalid, original, modified) is None,
  )
}
