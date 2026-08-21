// White-box behavior tests for `CoreDocumentDiffProvider`.
//
// The engine deviates from Monaco's by design (see the impl file header), so
// unlike the `*_reference_test.mbt` suites these do NOT byte-compare against
// Monaco's outputs: hunk boundaries may legally differ by tie-breaking among
// equal adjacent lines. Instead every case asserts
// - the invariants Monaco's own assertion harness enforces on any valid
//   result (sorted, strictly separated hunks with equal line deltas), and
// - a reconstruction round-trip: applying `changes` to the original must
//   reproduce the modified document exactly;
// plus exact hunks on fixtures where the minimal diff is unambiguous.

///|
let default_options : DocumentDiffOptions = { ignore_trim_whitespace: false }

///|
fn compute(
  original : Array[String],
  modified : Array[String],
  options? : DocumentDiffOptions = default_options,
) -> DocumentDiff {
  get_core_document_diff_provider().compute_diff(
    @model.TextSnapshot(original.join("\n")),
    @model.TextSnapshot(modified.join("\n")),
    options,
  )
}

///|
fn compute_with_provider(
  provider : &DocumentDiffProvider,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
  options : DocumentDiffOptions,
) -> DocumentDiff raise {
  provider.compute_diff(original, modified, options)
}

///|
test "Core provider satisfies the public provider contract" {
  let core = CoreDocumentDiffProvider()
  let provider : &DocumentDiffProvider = core
  let result = try! compute_with_provider(
    provider,
    @model.TextSnapshot("same\nbefore"),
    @model.TextSnapshot("same\nafter"),
    default_options,
  )
  assert_eq(result.changes.length(), 1)
  assert_true(result.additional_alignments.is_empty())
  let notifications = Ref(0)
  let subscription = provider.on_did_change(() => notifications.val += 1)
  subscription.dispose()
  assert_eq(notifications.val, 0)
}

///|
test "character refinement keeps unchanged text outside the inner ranges" {
  let result = compute(["return 1"], ["return 20"])
  assert_eq(result.changes.length(), 1)
  guard result.changes[0].get_inner_changes() is Some(changes) else {
    fail("expected character-level changes")
  }
  assert_eq(changes.length(), 1)
  let (original, modified) = changes[0]
  assert_eq(original, Range(1, 8, 1, 9))
  assert_eq(modified, Range(1, 8, 1, 10))
}

///|
test "character refinement anchors pure insertions and deletions" {
  let insertion = compute(["abc"], ["abXYc"])
  guard insertion.changes[0].get_inner_changes() is Some(insertions) else {
    fail("expected insertion refinement")
  }
  assert_eq(insertions.length(), 1)
  let (empty_original, inserted) = insertions[0]
  assert_eq(empty_original, Range(1, 3, 1, 3))
  assert_eq(inserted, Range(1, 3, 1, 5))

  let deletion = compute(["abXYc"], ["abc"])
  guard deletion.changes[0].get_inner_changes() is Some(deletions) else {
    fail("expected deletion refinement")
  }
  assert_eq(deletions.length(), 1)
  let (deleted, empty_modified) = deletions[0]
  assert_eq(deleted, Range(1, 3, 1, 5))
  assert_eq(empty_modified, Range(1, 3, 1, 3))
}

///|
test "character refinement keeps supplementary characters atomic" {
  let result = compute(["x😀y"], ["x😃y"])
  assert_eq(result.changes.length(), 1)
  guard result.changes[0].get_inner_changes() is Some(changes) else {
    fail("expected character-level changes")
  }
  assert_eq(changes.length(), 1)
  let (original, modified) = changes[0]
  assert_eq(original, Range(1, 2, 1, 4))
  assert_eq(modified, Range(1, 2, 1, 4))
}

///|
test "oversized character refinement falls back to line changes" {
  let original = "a".repeat(MaxInnerDiffCodeUnits + 1)
  let modified = "b".repeat(MaxInnerDiffCodeUnits + 1)
  let result = compute([original], [modified])
  assert_eq(result.changes.length(), 1)
  assert_true(result.changes[0].get_inner_changes() is None)
}

///|
/// Applies `changes` to `original`: copy unchanged original lines, splice in
/// the modified side of each hunk.
fn apply_changes(
  original : Array[String],
  modified : Array[String],
  changes : Array[DetailedLineRangeMapping],
) -> Array[String] {
  let result : Array[String] = []
  let mut next_original_line = 1
  for change in changes {
    for line in next_original_line..<change.original.start_line_number {
      result.push(original[line - 1])
    }
    for
      line in change.modified.start_line_number..<change.modified.end_line_number_exclusive {
      result.push(modified[line - 1])
    }
    next_original_line = change.original.end_line_number_exclusive
  }
  for line in next_original_line..<(original.length() + 1) {
    result.push(original[line - 1])
  }
  result
}

///|
/// The invariants `lineRangeMappingFromRangeMappings`' assertion enforces
/// (`rangeMapping.ts:340-356`): hunks are sorted, strictly separated by at
/// least one unchanged line on both sides, and the gap between consecutive
/// hunks is the same number of lines on both sides.
fn assert_valid(
  original : Array[String],
  modified : Array[String],
  result : DocumentDiff,
) -> Unit raise {
  for i in 1..<result.changes.length() {
    let m1 = result.changes[i - 1]
    let m2 = result.changes[i]
    assert_true(
      m1.original.end_line_number_exclusive < m2.original.start_line_number,
    )
    assert_true(
      m1.modified.end_line_number_exclusive < m2.modified.start_line_number,
    )
    assert_eq(
      m2.original.start_line_number - m1.original.end_line_number_exclusive,
      m2.modified.start_line_number - m1.modified.end_line_number_exclusive,
    )
  }
  assert_eq(
    apply_changes(original, modified, result.changes).join("\n"),
    modified.join("\n"),
  )
}

///|
test "interleaved edits round-trip" {
  let original = [
    "package demo", "", "fn alpha() {", "  return 1", "}", "", "fn beta() {", "  return 2",
    "}", "", "fn gamma() {", "  return 3", "}",
  ]
  let modified = [
    "package demo", "", "// docs", "fn alpha() {", "  return 10", "}", "", "fn beta() {",
    "  return 2", "}", "", "fn delta() {", "  return 4", "}", "", "fn gamma() {",
    "  return 3", "}",
  ]
  let result = compute(original, modified)
  assert_valid(original, modified, result)
  assert_true(result.changes.length() >= 2)
}

///|
test "repeated equal lines still yield a valid separated script" {
  // Repetition is where Myers tie-breaking has latitude; the exact hunk
  // placement is unspecified, validity is not.
  let original = ["x", "x", "x", "x", "x"]
  let modified = ["x", "x", "y", "x", "x", "x"]
  let result = compute(original, modified)
  assert_valid(original, modified, result)
}

///|
test "large Core Myers calculation still yields a correct script" {
  let original : Array[String] = []
  let modified : Array[String] = []
  for i in 0..<200 {
    original.push("line \{i}")
    modified.push(if i % 7 == 0 { "line \{i} changed" } else { "line \{i}" })
  }
  let result = compute(original, modified)
  assert_valid(original, modified, result)
}

///|
test "trim whitespace policy ignores only line edges" {
  let original = ["fn main {", "value + other", "}"]
  let indentation_only = [" fn main { ", "  value + other\t", "}"]
  let interior_change = ["fn main {", "value  + other", "}"]
  let options : DocumentDiffOptions = { ignore_trim_whitespace: true }
  assert_true(compute(original, indentation_only, options~).changes.is_empty())
  assert_eq(compute(original, interior_change, options~).changes.length(), 1)
}

///|
test "trim whitespace is excluded from mixed character refinements" {
  let result = compute(["  x=1"], ["x=2  "], options={
    ignore_trim_whitespace: true,
  })
  guard result.changes is [change] && change.inner_changes is Some([inner]) else {
    fail("expected one content-only inner change")
  }
  assert_eq(inner.original, Range(1, 5, 1, 6))
  assert_eq(inner.modified, Range(1, 3, 1, 4))
}

///|
test "trim whitespace treats whitespace-only and empty documents as equal" {
  let ignore : DocumentDiffOptions = { ignore_trim_whitespace: true }
  let preserve : DocumentDiffOptions = { ignore_trim_whitespace: false }
  assert_true(compute(["   "], [""], options=ignore).changes.is_empty())
  assert_true(compute([""], ["\t"], options=ignore).changes.is_empty())
  assert_eq(compute(["   "], [""], options=preserve).changes.length(), 1)
  assert_eq(compute([""], ["\t"], options=preserve).changes.length(), 1)
}

///|
test "snapshot normalization makes CRLF and LF equal" {
  let provider = CoreDocumentDiffProvider()
  let result = provider.compute_diff(
    @model.TextSnapshot("one\r\ntwo\r\n"),
    @model.TextSnapshot("one\ntwo\n"),
    default_options,
  )
  assert_true(result.changes.is_empty())
}

///|
test "combining marks and ZWJ sequences keep UTF-16 range coordinates" {
  let combining = compute(["cafe\u{301}"], ["cafe"])
  guard combining.changes[0].inner_changes is Some(combining_changes) else {
    fail("expected combining-mark refinement")
  }
  assert_eq(combining_changes[0].original, Range(1, 5, 1, 6))
  assert_eq(combining_changes[0].modified, Range(1, 5, 1, 5))

  let zwj = compute(["x👩‍💻y"], ["x👨‍💻y"])
  guard zwj.changes[0].inner_changes is Some(zwj_changes) else {
    fail("expected ZWJ refinement")
  }
  assert_eq(zwj_changes[0].original, Range(1, 2, 1, 4))
  assert_eq(zwj_changes[0].modified, Range(1, 2, 1, 4))
}

///|
test "tabs CJK and RTL text keep logical UTF-16 columns" {
  let cjk = compute(["\t中文x"], ["\t中語x"])
  guard cjk.changes[0].inner_changes is Some(cjk_changes) else {
    fail("expected CJK refinement")
  }
  assert_eq(cjk_changes[0].original, Range(1, 3, 1, 4))
  assert_eq(cjk_changes[0].modified, Range(1, 3, 1, 4))

  let rtl = compute(["אבג"], ["אדג"])
  guard rtl.changes[0].inner_changes is Some(rtl_changes) else {
    fail("expected RTL refinement")
  }
  assert_eq(rtl_changes[0].original, Range(1, 2, 1, 3))
  assert_eq(rtl_changes[0].modified, Range(1, 2, 1, 3))
}

///|
test "external-provider mapping shapes are directly constructible" {
  let line_mapping = LineRangeMapping(LineRange(2, 3), LineRange(4, 5))
  let inner = RangeMapping(Range(2, 1, 2, 2), Range(4, 1, 4, 3))
  let detailed = DetailedLineRangeMapping(
    line_mapping.original,
    line_mapping.modified,
    Some([inner]),
  )
  assert_eq(detailed.line_mapping(), line_mapping)
  assert_eq(detailed.inner_changes, Some([inner]))
}
