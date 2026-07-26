///|
/// Protected MoonBit source and manifest names, as they appear at the end of a
/// path in a denial line. Matched with `line_names_subject`, so `.mbt` does not
/// also cover `.mbt.md` — both are listed.
let protected_source_subjects : ReadOnlyArray[String] = [
  ".mbt.md", ".mbt", ".mbti", "moon.mod.json", "moon.pkg.json", "moon.mod", "moon.pkg",
  "moon.work",
]

///|
/// Return whether child-process output contains a likely protected-source
/// write denial.
///
/// Matching is line-oriented. A line must contain a recognized
/// "Operation not permitted" or "Permission denied" form and name either a
/// protected source suffix or one of `denial_subjects`. Pass the subjects from
/// the `SourceWriteProfileData` used for that child. Unrelated permission
/// errors and mentions of source files without a denial are ignored.
///
/// A protected source name is recognized on its own, so the common denials need
/// no subjects at all — including the shape MoonBit's own runtime produces,
/// where the path is wrapped in escaped quotes:
///
/// ```mbt check
/// test "denials that name a protected source file" {
///   inspect(
///     @sandbox.source_write_denied_in_text(
///       "sh: main.mbt: Operation not permitted\n",
///       [],
///     ),
///     content="true",
///   )
///   inspect(
///     @sandbox.source_write_denied_in_text(
///       "sh: moon.work: Operation not permitted\n",
///       [],
///     ),
///     content="true",
///   )
///   // run_moonbit's shape: a MoonBit runtime error for a denied source write.
///   inspect(
///     @sandbox.source_write_denied_in_text(
///       "OSError(\"@fs.open(): \\\"keep.mbt\\\": Operation not permitted\")",
///       [],
///     ),
///     content="true",
///   )
///   // The subject may also follow the denial (python's errno shape).
///   inspect(
///     @sandbox.source_write_denied_in_text(
///       "PermissionError: [Errno 1] Operation not permitted: 'main.mbt'\n",
///       [],
///     ),
///     content="true",
///   )
/// }
/// ```
///
/// Both halves must hold on the same line. That is what keeps an unrelated
/// permission error, or a build log that merely mentions a source file, from
/// reading as a sandbox denial:
///
/// ```mbt check
/// test "a denial alone, or a source name alone, is not a source-write denial" {
///   inspect(
///     @sandbox.source_write_denied_in_text("Permission denied\n", []),
///     content="false",
///   )
///   inspect(
///     @sandbox.source_write_denied_in_text(
///       "Permission denied while reading main.mbt\n",
///       [],
///     ),
///     content="false",
///   )
///   inspect(
///     @sandbox.source_write_denied_in_text("compiled keep.mbt: ok\n", []),
///     content="false",
///   )
/// }
/// ```
///
/// A denied *directory* carries no protected suffix, so it is recognized only
/// when the profile's own subjects name it. This is why callers must pass the
/// `denial_subjects` from the `SourceWriteProfileData` they ran the child with,
/// rather than an empty array:
///
/// ```mbt check
/// test "a directory denial is recognized only through its subject" {
///   let denial = "PermissionError: [Errno 1] Operation not permitted: 'pkg'\n"
///   inspect(@sandbox.source_write_denied_in_text(denial, []), content="false")
///   inspect(@sandbox.source_write_denied_in_text(denial, ["pkg"]), content="true")
///   // An unrelated name is not rescued by having subjects.
///   inspect(
///     @sandbox.source_write_denied_in_text("foo: Operation not permitted\n", [
///       "pkg",
///     ]),
///     content="false",
///   )
/// }
/// ```
pub fn source_write_denied_in_text(
  output_text : String,
  denial_subjects : Array[String],
) -> Bool {
  output_text
  .split("\n")
  .any(line => {
    // Both halves must hold on the SAME line. Checking them across the whole
    // output would match any log that mentions a source file and, separately,
    // hits an unrelated permission error.
    let mentions_denial = line.contains("Operation not permitted") ||
      line.contains("operation not permitted") ||
      line.contains(": Permission denied") ||
      line.contains("Permission denied:")
    mentions_denial &&
    (
      protected_source_subjects.any(suffix => line_names_subject(line, suffix)) ||
      denial_subjects.any(subject => {
        subject != "" && line_names_subject(line, subject)
      })
    )
  })
}

///|
/// Whether `line` names `subject` as the object of an error rather than merely
/// containing it as a substring: the tool's own punctuation or quoting follows
/// it, or the line ends with it after a denial's colon.
///
/// Shared by the protected-suffix scan and the profile's denial subjects, which
/// need the identical notion of "names".
fn line_names_subject(line : StringView, subject : String) -> Bool {
  line.contains("\{subject}:") ||
  line.contains("\{subject}'") ||
  line.contains("\{subject}\"") ||
  // MoonBit's own OSError Show output escapes the quotes around the path
  // (`@fs.open(): \"keep.mbt\": Operation not permitted`), so the subject is
  // followed by `\"`, not a bare quote — run_moonbit's denial shape.
  line.contains("\{subject}\\\"") ||
  line.contains("\{subject}`") ||
  (
    (
      line.contains("Operation not permitted:") ||
      line.contains("operation not permitted:") ||
      line.contains("Permission denied:")
    ) &&
    line.has_suffix(subject)
  )
}
