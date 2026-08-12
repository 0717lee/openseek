// Conservative resolution of transcript file references. A trailing
// `:line[:column]` or `#Lline` is only treated as an editor position after the
// literal path is known not to exist and the path before it is a regular file.

///|
/// One literal path surfaced by the agent and clicked by the user.
pub(all) struct Reference(String) derive(Debug, Eq)

///|
/// What the host should do with a transcript file reference.
pub(all) enum Resolution {
  // Preserve the literal path. This covers ordinary paths, real filenames
  // ending in `:<number>` or `#L<number>`, and missing paths whose
  // system-opener error remains the most truthful result.
  SystemPath(String)
  // The literal path was absent, while this suffix-free regular file exists.
  // The frontend can therefore open its editor at the parsed position.
  EditorPath(path~ : String, line~ : Int, column~ : Int?)
} derive(Debug, Eq)

///|
priv struct EditorCandidate {
  path : String
  line : Int
  column : Int?
}

///|
/// Resolve this reference without letting suffix syntax override a real path.
/// Filesystem errors other than a definite absence preserve the literal path:
/// permissions or a transient stat failure must not silently redirect a click
/// to a different file.
pub async fn Reference::resolve(self : Reference) -> Resolution {
  guard self.editor_candidate() is Some(candidate) else {
    return SystemPath(self.0)
  }
  let literal_exists = Some(@fs.exists(self.0)) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
  guard literal_exists == Some(false) else { return SystemPath(self.0) }
  let candidate_kind = Some(@fs.kind(candidate.path)) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
  if candidate_kind == Some(Regular) {
    EditorPath(
      path=candidate.path,
      line=candidate.line,
      column=candidate.column,
    )
  } else {
    SystemPath(self.0)
  }
}

///|
/// Parse conventional editor-position suffixes. A Markdown destination may use
/// GitHub's `#Lline`; colon positions are parsed from right to left, and the
/// second numeric component is a column only when the preceding component is
/// also a positive integer. This keeps a Windows drive colon and ordinary
/// colons in the path.
fn Reference::editor_candidate(self : Reference) -> EditorCandidate? {
  if self.0.rev_split_once("#L") is Some((path, line_text)) {
    let line = @string.parse_int(line_text, base=10) catch { _ => 0 }
    if line > 0 && !path.is_empty() {
      return Some({ path: path.to_owned(), line, column: None })
    }
  }
  guard self.0.rev_split_once(":") is Some((before_last, last_text)) else {
    return None
  }
  let last = @string.parse_int(last_text, base=10) catch { _ => 0 }
  guard last > 0 && !before_last.is_empty() else { return None }
  if before_last.rev_split_once(":") is Some((path, line_text)) {
    let line = @string.parse_int(line_text, base=10) catch { _ => 0 }
    if line > 0 && !path.is_empty() {
      return Some({ path: path.to_owned(), line, column: Some(last) })
    }
  }
  Some({ path: before_last.to_owned(), line: last, column: None })
}
