///|
/// The exhaustive line-level pins for `source_write_denied_in_text`. The
/// docstring on that function carries the teaching subset; this is the spec.
///
/// Black-box on purpose: detection is entirely a property of the public API, so
/// these exercise it exactly as `shell`, `shell_output`, and `run_moonbit` do.
test "source-write denial detection in command output" {
  // run_moonbit's shape: a MoonBit runtime error for a denied source write.
  assert_true(
    @sandbox.source_write_denied_in_text(
      "OSError(\"@fs.open(): \\\"keep.mbt\\\": Operation not permitted\")",
      [],
    ),
  )
  assert_true(
    @sandbox.source_write_denied_in_text(
      "sh: main.mbt: Operation not permitted\n",
      [],
    ),
  )
  assert_true(
    @sandbox.source_write_denied_in_text(
      "sh: moon.work: Operation not permitted\n",
      [],
    ),
  )
  // Generic denials and prose mentions are not source-write denials.
  assert_false(@sandbox.source_write_denied_in_text("Permission denied\n", []))
  assert_false(
    @sandbox.source_write_denied_in_text(
      "Permission denied while reading main.mbt\n",
      [],
    ),
  )
  assert_false(
    @sandbox.source_write_denied_in_text(
      "Permission denied while reading 'main.mbt'\n",
      [],
    ),
  )
  // The subject may follow the denial (python's errno shape, plain colon).
  assert_true(
    @sandbox.source_write_denied_in_text(
      "PermissionError: [Errno 1] Operation not permitted: 'main.mbt'\n",
      [],
    ),
  )
  assert_true(
    @sandbox.source_write_denied_in_text(
      "Operation not permitted: main.mbt\n",
      [],
    ),
  )
  assert_true(
    @sandbox.source_write_denied_in_text("Permission denied: main.mbt\n", []),
  )
  // A denied directory is recognized only as a known denial subject.
  let dir_rename = "PermissionError: [Errno 1] Operation not permitted: 'pkg'\n"
  assert_false(@sandbox.source_write_denied_in_text(dir_rename, []))
  assert_true(@sandbox.source_write_denied_in_text(dir_rename, ["pkg"]))
  assert_false(
    @sandbox.source_write_denied_in_text("foo: Operation not permitted\n", []),
  )
  assert_false(
    @sandbox.source_write_denied_in_text("foo: Operation not permitted\n", [
      "pkg",
    ]),
  )
  // A source path without any denial wording is not a denial either.
  assert_false(
    @sandbox.source_write_denied_in_text("compiled keep.mbt: ok", []),
  )
}
