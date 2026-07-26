///|
/// The exhaustive line-level pins for denial classification. The docstring on
/// `SourceWriteDenialClassifier::output_reports_denial` carries the teaching
/// subset; this is the spec.
///
/// Black-box on purpose: detection is entirely a property of the public API, so
/// these exercise it exactly as `shell`, `shell_output`, and `run_moonbit` do.
fn reports(subjects : Array[String], text : String) -> Bool {
  @sandbox.SourceWriteDenialClassifier::with_subjects(subjects).output_reports_denial(
    text,
  )
}

///|
test "source-write denial detection in command output" {
  // run_moonbit's shape: a MoonBit runtime error for a denied source write.
  assert_true(
    reports(
      [],
      "OSError(\"@fs.open(): \\\"keep.mbt\\\": Operation not permitted\")",
    ),
  )
  assert_true(reports([], "sh: main.mbt: Operation not permitted\n"))
  assert_true(reports([], "sh: moon.work: Operation not permitted\n"))
  // Generic denials and prose mentions are not source-write denials.
  assert_false(reports([], "Permission denied\n"))
  assert_false(reports([], "Permission denied while reading main.mbt\n"))
  assert_false(reports([], "Permission denied while reading 'main.mbt'\n"))
  // The subject may follow the denial (python's errno shape, plain colon).
  assert_true(
    reports(
      [],
      "PermissionError: [Errno 1] Operation not permitted: 'main.mbt'\n",
    ),
  )
  assert_true(reports([], "Operation not permitted: main.mbt\n"))
  assert_true(reports([], "Permission denied: main.mbt\n"))
  // A denied directory is recognized only as a known denial subject.
  let dir_rename = "PermissionError: [Errno 1] Operation not permitted: 'pkg'\n"
  assert_false(reports([], dir_rename))
  assert_true(reports(["pkg"], dir_rename))
  assert_false(reports([], "foo: Operation not permitted\n"))
  assert_false(reports(["pkg"], "foo: Operation not permitted\n"))
  // A source path without any denial wording is not a denial either.
  assert_false(reports([], "compiled keep.mbt: ok"))
}
