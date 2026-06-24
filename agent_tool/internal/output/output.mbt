///|
/// Truncate `content` to at most `max_chars` UTF-16 code units, returning it
/// unchanged when it already fits. A budget landing in the middle of a
/// surrogate pair steps back one unit so the kept prefix is always valid text.
pub fn cap_text(content : String, max_chars : Int) -> String {
  if content.length() <= max_chars {
    content
  } else {
    "\{content[:char_boundary_at_or_below(content, max_chars)]}"
  }
}

///|
/// Largest code-unit offset `<= max_units` that is a valid character boundary.
/// A surrogate pair spans two code units; if `max_units` lands on the trailing
/// surrogate, step back one so the leading surrogate is dropped too. Only
/// reached with `0 <= max_units < content.length()`.
fn char_boundary_at_or_below(content : String, max_units : Int) -> Int {
  if max_units > 0 && content[max_units].is_trailing_surrogate() {
    max_units - 1
  } else {
    max_units
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
    let shown_chars = char_boundary_at_or_below(content, max_chars)
    "\ntruncated=true\noutput_chars=\{content.length()}\nshown_chars=\{shown_chars}"
  } else {
    ""
  }
}
