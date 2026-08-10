///|
/// Keep at most `max_units` leading UTF-16 code units of `content` without
/// ever splitting a surrogate pair. This is a soft cap for rendered output, so
/// it returns the full string when already within budget.
pub fn code_unit_prefix(content : StringView, max_units : Int) -> StringView {
  content.clamped_view(end=max_units)
}
