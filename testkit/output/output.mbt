///|
/// Redact a temporary fixture root from command output while preserving stable
/// fixture-relative suffixes across Windows and Unix path spellings.
pub fn redact_fixture_root(
  content : String,
  root~ : String,
  canonical? : String = "",
  replacement? : String = "<fixture>",
) -> String {
  let mut output = content.replace_all(old="\r\n", new="\n")
  output = redact_one_root(output, root, replacement)
  if canonical != "" && canonical != root {
    output = redact_one_root(output, canonical, replacement)
  }
  output
}

///|
test "redact_fixture_root keeps fixture-relative suffix stable" {
  let root = "C:\\Users\\runneradmin\\AppData\\Local\\Temp\\openseek-fixture"
  let output =
    #|cwd=C:\Users\runneradmin\AppData\Local\Temp\openseek-fixture
    #|path=C:\Users\runneradmin\AppData\Local\Temp\openseek-fixture\lib.mbt
  assert_eq(
    redact_fixture_root(output, root~),
    (
      #|cwd=<fixture>
      #|path=<fixture>/lib.mbt
    ),
  )
}

///|
fn redact_one_root(
  content : String,
  root : String,
  replacement : String,
) -> String {
  let root_path : @path.Path = root
  let normalized = root_path.normalize().to_string()
  let mut output = content
  output = replace_root_spelling(output, root, replacement)
  output = replace_root_spelling(output, normalized, replacement)
  output = replace_root_spelling(
    output,
    normalized.replace_all(old="\\", new="/"),
    replacement,
  )
  replace_root_spelling(
    output,
    normalized.replace_all(old="/", new="\\"),
    replacement,
  )
}

///|
fn replace_root_spelling(
  content : String,
  spelling : String,
  replacement : String,
) -> String {
  if spelling == "" {
    return content
  }
  content
  .replace_all(old=spelling + "/", new=replacement + "/")
  .replace_all(old=spelling + "\\", new=replacement + "/")
  .replace_all(old=spelling, new=replacement)
}
