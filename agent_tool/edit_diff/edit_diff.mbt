///|
/// Render the line-oriented Patience diff from `old` to `new` as marker-prefixed
/// text. Equal lines start with two spaces, removals with `- `, and additions
/// with `+ `. The result intentionally contains the complete edit script rather
/// than unified-diff headers or context elision so callers can choose their own
/// HTML wrapper and truncation policy.
pub fn generate(old : String, new : String) -> String {
  let old_lines = text_lines(old)
  let new_lines = text_lines(new)
  let diff = @diff.Diff(old=old_lines, new=new_lines, algorithm=Patience)
  let rendered : Array[String] = []
  for edit in diff.edits() {
    match edit {
      Equal(old_index~, len~, ..) =>
        for line in old_lines[old_index:old_index + len] {
          rendered.push("  \{line}")
        }
      Delete(old_index~, old_len~, ..) =>
        for line in old_lines[old_index:old_index + old_len] {
          rendered.push("- \{line}")
        }
      Insert(new_index~, new_len~, ..) =>
        for line in new_lines[new_index:new_index + new_len] {
          rendered.push("+ \{line}")
        }
    }
  }
  rendered.join("\n")
}

///|
/// Split non-empty text into line views. An empty tool string represents an
/// absent side of the edit, not one empty line.
fn text_lines(text : String) -> Array[StringView] {
  if text == "" {
    []
  } else {
    [..text.split("\n")]
  }
}
