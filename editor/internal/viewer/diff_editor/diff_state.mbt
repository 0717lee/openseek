// The renderer-facing state mirrors VS Code's DiffState/DiffMapping boundary.
// A real change has exactly one canonical DetailedLineRangeMapping. The only
// local extension is `additional_alignments`; those mappings are injected into
// alignment computation and are deliberately absent from every visual feature.

///|
pub struct DiffMapping {
  line_range_mapping : @diff.DetailedLineRangeMapping
}

///|
pub struct DiffState {
  mappings : Array[DiffMapping]
  additional_alignments : Array[@diff.LineRangeMapping]
}

///|
fn DiffState::from_diff_result(result : @diff.DocumentDiff) -> DiffState {
  {
    mappings: result.changes.map(change => { line_range_mapping: change }),
    additional_alignments: result.additional_alignments.copy(),
  }
}

///|
fn DiffState::mapping_count(self : DiffState) -> Int {
  self.mappings.length()
}

///|
fn DiffState::mapping_at(
  self : DiffState,
  index : Int,
) -> @diff.DetailedLineRangeMapping? {
  if index < 0 || index >= self.mappings.length() {
    None
  } else {
    Some(self.mappings[index].line_range_mapping)
  }
}

///|
priv struct IndexedDiffAlignment {
  source_index : Int
  line_range_mapping : @diff.LineRangeMapping
  diff : @diff.DetailedLineRangeMapping?
}

///|
fn compare_line_range(
  left : @base_common.LineRange,
  right : @base_common.LineRange,
) -> Int {
  if left.start_line_number != right.start_line_number {
    left.start_line_number - right.start_line_number
  } else {
    left.end_line_number_exclusive - right.end_line_number_exclusive
  }
}

///|
fn compare_indexed_diff_alignment(
  left : IndexedDiffAlignment,
  right : IndexedDiffAlignment,
) -> Int {
  let original = compare_line_range(
    left.line_range_mapping.original,
    right.line_range_mapping.original,
  )
  if original != 0 {
    return original
  }
  let modified = compare_line_range(
    left.line_range_mapping.modified,
    right.line_range_mapping.modified,
  )
  if modified != 0 {
    return modified
  }
  left.source_index - right.source_index
}

///|
priv struct DiffAlignment {
  line_range_mapping : @diff.LineRangeMapping
  /// `None` is the sole extension point: a geometry-only alignment must never
  /// be mistaken for a visible diff mapping.
  diff : @diff.DetailedLineRangeMapping?
}

///|
fn DiffState::alignments(self : DiffState) -> Array[DiffAlignment] {
  let indexed : Array[IndexedDiffAlignment] = []
  for mapping in self.mappings {
    indexed.push({
      source_index: indexed.length(),
      line_range_mapping: mapping.line_range_mapping.line_mapping(),
      diff: Some(mapping.line_range_mapping),
    })
  }
  for alignment in self.additional_alignments {
    indexed.push({
      source_index: indexed.length(),
      line_range_mapping: alignment,
      diff: None,
    })
  }
  indexed.sort_by(compare_indexed_diff_alignment)
  indexed.map(item => {
    line_range_mapping: item.line_range_mapping,
    diff: item.diff,
  })
}

///|
priv struct DiffNavigationTarget {
  change_index : Int
  change_count : Int
  change : @diff.DetailedLineRangeMapping
}

///|
fn DiffState::next_change(
  self : DiffState,
  current_change_index : Int?,
) -> DiffNavigationTarget? {
  let count = self.mapping_count()
  if count == 0 {
    return None
  }
  let index = match current_change_index {
    Some(current) if current >= 0 && current < count => (current + 1) % count
    _ => 0
  }
  Some({
    change_index: index,
    change_count: count,
    change: self.mappings[index].line_range_mapping,
  })
}

///|
fn DiffState::previous_change(
  self : DiffState,
  current_change_index : Int?,
) -> DiffNavigationTarget? {
  let count = self.mapping_count()
  if count == 0 {
    return None
  }
  let index = match current_change_index {
    Some(current) if current >= 0 && current < count =>
      (current - 1 + count) % count
    _ => count - 1
  }
  Some({
    change_index: index,
    change_count: count,
    change: self.mappings[index].line_range_mapping,
  })
}
