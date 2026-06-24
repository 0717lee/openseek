///|
/// Truncate `content` to at most `max_chars` UTF-16 code units, returning it
/// unchanged when it already fits.
pub fn cap_text(content : String, max_chars : Int) -> String {
  if content.length() <= max_chars {
    content
  } else {
    "\{content[:max_chars]}"
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
/// `max_chars`, or the empty string when nothing was dropped.
pub fn truncation_header(content : String, max_chars : Int) -> String {
  if is_truncated(content, max_chars) {
    "\ntruncated=true\noutput_chars=\{content.length()}\nshown_chars=\{max_chars}"
  } else {
    ""
  }
}
