///|
/// Return whether child-process output contains a likely protected-source
/// write denial.
///
/// Matching is line-oriented. A line must contain a recognized
/// "Operation not permitted" or "Permission denied" form and name either a
/// protected source suffix or one of `denial_subjects`. Pass the subjects from
/// the `SourceWriteProfileData` used for that child. Unrelated permission
/// errors and mentions of source files without a denial are ignored.
pub fn source_write_denied_in_text(
  output_text : String,
  denial_subjects : Array[String],
) -> Bool {
  output_text
  .split("\n")
  .any(line => {
    sandbox_denial_line_mentions_denial(line) &&
    (
      sandbox_denial_line_mentions_source_path(line) ||
      sandbox_denial_line_mentions_known_subject(line, denial_subjects)
    )
  })
}

///|
fn sandbox_denial_line_mentions_known_subject(
  line : StringView,
  denial_subjects : Array[String],
) -> Bool {
  denial_subjects.any(subject => {
    subject != "" && sandbox_denial_line_mentions_literal_subject(line, subject)
  })
}

///|
fn sandbox_denial_line_mentions_literal_subject(
  line : StringView,
  subject : String,
) -> Bool {
  line.contains("\{subject}:") ||
  line.contains("\{subject}'") ||
  line.contains("\{subject}\"") ||
  // MoonBit's own OSError Show output escapes the quotes around the path
  // (`@fs.open(): \"keep.mbt\": Operation not permitted`), so the subject is
  // followed by `\"`, not a bare quote — run_moonbit's denial shape.
  line.contains("\{subject}\\\"") ||
  line.contains("\{subject}`") ||
  (
    sandbox_denial_line_has_denial_colon_before_subject(line) &&
    line.has_suffix(subject)
  )
}

///|
fn sandbox_denial_line_mentions_source_path(line : StringView) -> Bool {
  [
    ".mbt.md", ".mbt", ".mbti", "moon.mod.json", "moon.pkg.json", "moon.mod", "moon.pkg",
    "moon.work",
  ].any(suffix => sandbox_denial_line_mentions_literal_subject(line, suffix))
}

///|
fn sandbox_denial_line_mentions_denial(line : StringView) -> Bool {
  line.contains("Operation not permitted") ||
  line.contains("operation not permitted") ||
  line.contains(": Permission denied") ||
  line.contains("Permission denied:")
}

///|
fn sandbox_denial_line_has_denial_colon_before_subject(
  line : StringView,
) -> Bool {
  line.contains("Operation not permitted:") ||
  line.contains("operation not permitted:") ||
  line.contains("Permission denied:")
}
