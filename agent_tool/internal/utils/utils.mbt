///|
/// Largest code-unit offset `<= max_units` that is a valid UTF-16 character
/// boundary. A surrogate pair spans two code units; if `max_units` lands on a
/// trailing surrogate, step back one so a cut there never splits the pair.
/// `max_units <= 0` is returned unchanged. Callers pass `max_units <
/// content.length()` so the index access stays in bounds.
///
/// Shared by every tool that caps output to a UTF-16 code-unit budget (`read`
/// renders numbered lines, `agent_tool/internal/output` caps tool output) so
/// the surrogate-safety rule lives in exactly one place.
pub fn char_boundary_at_or_below(content : String, max_units : Int) -> Int {
  if max_units > 0 && content[max_units].is_trailing_surrogate() {
    max_units - 1
  } else {
    max_units
  }
}
