///|
/// Truncate `content` to at most `max_chars` UTF-16 code units, returning it
/// unchanged when it already fits. A budget landing in the middle of a
/// surrogate pair steps back one unit so the kept prefix is always valid text.
pub fn cap_text(content : String, max_chars : Int) -> String {
  if content.length() <= max_chars {
    content
  } else {
    "\{content[:@utils.char_boundary_at_or_below(content, max_chars)]}"
  }
}

///|
/// Whether `content` is longer than `max_chars`, i.e. whether `cap_text` would
/// drop characters from it.
pub fn is_truncated(content : String, max_chars : Int) -> Bool {
  content.length() > max_chars
}

///|
/// A trailing metadata block describing the truncation of `content` at
/// `max_chars`, or the empty string when nothing was dropped. `shown_chars`
/// is the length actually kept by `cap_text`, which can be one less than
/// `max_chars` when the budget would have split a surrogate pair.
pub fn truncation_header(content : String, max_chars : Int) -> String {
  if is_truncated(content, max_chars) {
    let shown_chars = @utils.char_boundary_at_or_below(content, max_chars)
    "\ntruncated=true\noutput_chars=\{content.length()}\nshown_chars=\{shown_chars}"
  } else {
    ""
  }
}
