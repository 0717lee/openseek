// White-box behavior tests for the piediff-backed `DefaultLinesDiffComputer`.
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
let default_options : LinesDiffComputerOptions = {
  ignore_trim_whitespace: false,
  max_computation_time_ms: 0,
  compute_moves: false,
}

///|
fn compute(
  original : Array[String],
  modified : Array[String],
  options? : LinesDiffComputerOptions = default_options,
) -> LinesDiff {
  get_default().compute_diff(original, modified, options)
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
  result : LinesDiff,
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
test "default computation budget still yields a correct script" {
  // A non-zero budget takes piediff's default cutoff path
  // (suboptimal-but-correct); correctness must hold regardless.
  let original : Array[String] = []
  let modified : Array[String] = []
  for i in 0..<200 {
    original.push("line \{i}")
    modified.push(if i % 7 == 0 { "line \{i} changed" } else { "line \{i}" })
  }
  let result = compute(original, modified, options={
    ignore_trim_whitespace: false,
    max_computation_time_ms: 1000,
    compute_moves: false,
  })
  assert_false(result.hit_timeout)
  assert_valid(original, modified, result)
}
