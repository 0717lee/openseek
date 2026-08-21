// Character-level refinement for one line-level diff hunk. Core diff compares
// Unicode scalar values so a supplementary character remains atomic, while
// the parallel boundary table retains the Viewer's one-based UTF-16 columns.
// Newline sentinels let matching continue across a multi-line replacement.

///|
/// Avoid turning a large whole-file replacement into two additional scalar
/// arrays plus a potentially expensive character diff. The line-level result
/// remains complete when this refinement returns `None`.
const MaxInnerDiffCodeUnits = 20000

///|
priv struct InnerDiffSequence {
  values : Array[Int]
  boundaries : Array[@base_common.Position]
}

///|
priv struct InnerDiffLine {
  values : Array[Int]
  boundaries : Array[@base_common.Position]
}

///|
fn line_range_code_units(
  lines : Array[String],
  range : @base_common.LineRange,
) -> Int {
  let mut length = 0
  for line_number in range.start_line_number..<range.end_line_number_exclusive {
    length += lines[line_number - 1].length()
    if line_number + 1 < range.end_line_number_exclusive {
      length += 1
    }
  }
  length
}

///|
fn empty_line_range_anchor(
  lines : Array[String],
  line_number : Int,
) -> @base_common.Position {
  if lines.is_empty() {
    Position(1, 1)
  } else if line_number <= lines.length() {
    Position(line_number.max(1), 1)
  } else {
    let last_line_number = lines.length()
    Position(last_line_number, lines[last_line_number - 1].length() + 1)
  }
}

///|
fn flatten_inner_diff_line(
  line : String,
  line_number : Int,
  ignore_trim_whitespace : Bool,
) -> InnerDiffLine {
  let values : Array[Int] = []
  let whitespace : Array[Bool] = []
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  let mut column = 1
  for character in line {
    values.push(character.to_int())
    whitespace.push(character.is_whitespace())
    starts.push(column)
    column += character.utf16_len()
    ends.push(column)
  }
  let mut start = 0
  let mut end = values.length()
  if ignore_trim_whitespace {
    while start < end && whitespace[start] {
      start += 1
    }
    while end > start && whitespace[end - 1] {
      end -= 1
    }
  }
  let normalized : Array[Int] = []
  let anchor_column = if start < end { starts[start] } else { 1 }
  let boundaries : Array[@base_common.Position] = [
    Position(line_number, anchor_column),
  ]
  for index in start..<end {
    normalized.push(values[index])
    boundaries.push(Position(line_number, ends[index]))
  }
  { values: normalized, boundaries }
}

///|
fn flatten_inner_diff_sequence(
  lines : Array[String],
  range : @base_common.LineRange,
  ignore_trim_whitespace : Bool,
) -> InnerDiffSequence {
  if range.is_empty() {
    return {
      values: [],
      boundaries: [empty_line_range_anchor(lines, range.start_line_number)],
    }
  }
  let line_sequences : Array[InnerDiffLine] = []
  for line_number in range.start_line_number..<range.end_line_number_exclusive {
    line_sequences.push(
      flatten_inner_diff_line(
        lines[line_number - 1],
        line_number,
        ignore_trim_whitespace,
      ),
    )
  }
  let values : Array[Int] = []
  let boundaries : Array[@base_common.Position] = [
    line_sequences[0].boundaries[0],
  ]
  for line_index in 0..<line_sequences.length() {
    let line = line_sequences[line_index]
    for value_index in 0..<line.values.length() {
      values.push(line.values[value_index])
      boundaries.push(line.boundaries[value_index + 1])
    }
    if line_index + 1 < line_sequences.length() {
      values.push('\n'.to_int())
      boundaries.push(line_sequences[line_index + 1].boundaries[0])
    }
  }
  { values, boundaries }
}

///|
fn InnerDiffSequence::range(
  self : InnerDiffSequence,
  start : Int,
  end_exclusive : Int,
) -> @base_common.Range {
  @base_common.Range::from_positions(
    self.boundaries[start],
    self.boundaries[end_exclusive],
  )
}

///|
/// Refine one line mapping into maximal runs of changed Unicode scalars. Each
/// returned Range still uses UTF-16 columns, matching TextModel and Monaco.
fn compute_inner_changes(
  original_lines : Array[String],
  modified_lines : Array[String],
  original_range : @base_common.LineRange,
  modified_range : @base_common.LineRange,
  ignore_trim_whitespace : Bool,
) -> Array[RangeMapping]? {
  let original_length = line_range_code_units(original_lines, original_range)
  let modified_length = line_range_code_units(modified_lines, modified_range)
  if original_length > MaxInnerDiffCodeUnits ||
    modified_length > MaxInnerDiffCodeUnits ||
    original_length > MaxInnerDiffCodeUnits - modified_length {
    return None
  }
  let original = flatten_inner_diff_sequence(
    original_lines, original_range, ignore_trim_whitespace,
  )
  let modified = flatten_inner_diff_sequence(
    modified_lines, modified_range, ignore_trim_whitespace,
  )
  let edits = @core_diff.Diff::Diff(
    old=original.values[:],
    new=modified.values[:],
  ).edits()
  let changes : Array[RangeMapping] = []
  let mut index = 0
  while index < edits.length() {
    match edits[index] {
      Equal(..) => index += 1
      _ => {
        let mut original_start = 0x7FFFFFFF
        let mut original_end = -1
        let mut modified_start = 0x7FFFFFFF
        let mut modified_end = -1
        let mut original_anchor = 0
        let mut modified_anchor = 0
        while index < edits.length() {
          match edits[index] {
            Equal(..) => break
            Delete(old_index~, old_len~, new_index~) => {
              original_start = original_start.min(old_index)
              original_end = original_end.max(old_index + old_len)
              modified_anchor = new_index
            }
            Insert(old_index~, new_index~, new_len~) => {
              modified_start = modified_start.min(new_index)
              modified_end = modified_end.max(new_index + new_len)
              original_anchor = old_index
            }
          }
          index += 1
        }
        let original_change = if original_end >= 0 {
          original.range(original_start, original_end)
        } else {
          original.range(original_anchor, original_anchor)
        }
        let modified_change = if modified_end >= 0 {
          modified.range(modified_start, modified_end)
        } else {
          modified.range(modified_anchor, modified_anchor)
        }
        changes.push(RangeMapping(original_change, modified_change))
      }
    }
  }
  Some(changes)
}
