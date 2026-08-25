// DOM-independent projection of canonical diff changes into the paired line
// ranges that a later widget layer may hide. The threshold arithmetic follows
// VS Code's `UnchangedRegion.fromDiffs`; stateful reveal controls and model
// decorations remain outside this projection.

///|
fn hidden_range_from_unchanged_mapping(
  mapping : @diff.LineRangeMapping,
  original_line_count : Int,
  modified_line_count : Int,
  minimum_line_count : Int,
  context_line_count : Int,
) -> @diff.LineRangeMapping? {
  let mut original_start = mapping.original.start_line_number
  let mut modified_start = mapping.modified.start_line_number
  let mut length = mapping.original.length()
  let at_start = original_start == 1 && modified_start == 1
  let at_end = original_start + length == original_line_count + 1 &&
    modified_start + length == modified_line_count + 1
  if (at_start || at_end) && length >= context_line_count + minimum_line_count {
    if at_start && !at_end {
      length -= context_line_count
    }
    if at_end && !at_start {
      original_start += context_line_count
      modified_start += context_line_count
      length -= context_line_count
    }
  } else if length >= context_line_count * 2 + minimum_line_count {
    original_start += context_line_count
    modified_start += context_line_count
    length -= context_line_count * 2
  } else {
    return None
  }
  Some(
    LineRangeMapping(
      LineRange(original_start, original_start + length),
      LineRange(modified_start, modified_start + length),
    ),
  )
}

///|
/// Projects the unchanged gaps around canonical ordered changes into paired
/// hidden ranges. Empty diffs stay fully visible by local product contract;
/// otherwise leading/trailing gaps retain one context block and middle gaps
/// retain context on both sides.
pub fn project_hidden_unchanged_regions(
  changes : Array[@diff.DetailedLineRangeMapping],
  original_line_count : Int,
  modified_line_count : Int,
  minimum_line_count : Int,
  context_line_count : Int,
) -> Array[@diff.LineRangeMapping] {
  if changes.is_empty() {
    return []
  }
  let minimum_line_count = minimum_line_count.max(0)
  let context_line_count = context_line_count.max(0)
  let result : Array[@diff.LineRangeMapping] = []
  let mut previous_original_end = 1
  let mut previous_modified_end = 1
  for change in changes {
    let unchanged : @diff.LineRangeMapping = LineRangeMapping(
      LineRange(previous_original_end, change.original.start_line_number),
      LineRange(previous_modified_end, change.modified.start_line_number),
    )
    if !unchanged.modified.is_empty() {
      match
        hidden_range_from_unchanged_mapping(
          unchanged, original_line_count, modified_line_count, minimum_line_count,
          context_line_count,
        ) {
        Some(hidden) => result.push(hidden)
        None => ()
      }
    }
    previous_original_end = change.original.end_line_number_exclusive
    previous_modified_end = change.modified.end_line_number_exclusive
  }
  let unchanged : @diff.LineRangeMapping = LineRangeMapping(
    LineRange(previous_original_end, original_line_count + 1),
    LineRange(previous_modified_end, modified_line_count + 1),
  )
  if !unchanged.modified.is_empty() {
    match
      hidden_range_from_unchanged_mapping(
        unchanged, original_line_count, modified_line_count, minimum_line_count,
        context_line_count,
      ) {
      Some(hidden) => result.push(hidden)
      None => ()
    }
  }
  result
}
