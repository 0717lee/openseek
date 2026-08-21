// Renderer-neutral projections derived from a validated DocumentDiff.
//
// A DetailedLineRangeMapping remains the only representation of a real diff
// change. This file deliberately does not introduce a second viewer-specific
// change model. Instead, each feature stores only the small piece of derived
// data it needs. In particular, additional_alignments are appended only to
// the geometry anchors and can never become decorations, overview entries,
// or navigation targets.

///|
/// Decorations for one editor pane. Whole-line ranges cover the actual UTF-16
/// extent of their final model line; inner ranges retain the provider's
/// one-based UTF-16 coordinates unchanged.
pub struct DiffPaneDecorations {
  whole_line : Array[@base_common.Range]
  inner : Array[@base_common.Range]
}

///|
pub fn DiffPaneDecorations::whole_line_ranges(
  self : DiffPaneDecorations,
) -> Array[@base_common.Range] {
  self.whole_line.copy()
}

///|
pub fn DiffPaneDecorations::inner_ranges(
  self : DiffPaneDecorations,
) -> Array[@base_common.Range] {
  self.inner.copy()
}

///|
/// One overview-ruler entry. `change_index` addresses the projection's sorted
/// change array, while `range` is the non-empty range rendered by this pane.
pub(all) struct DiffOverviewEntry {
  change_index : Int
  range : @base_common.LineRange
} derive(Eq, Debug)

///|
/// A cyclic F7 navigation result. The mapping is the canonical provider
/// mapping rather than a viewer-specific copy of its fields.
pub(all) struct DiffNavigationTarget {
  change_index : Int
  change_count : Int
  change : @diff.DetailedLineRangeMapping
} derive(Eq, Debug)

///|
/// Pure feature data for one diff generation. Consumers apply these values in
/// the transaction order owned by DiffEditorWidget; this type owns no model,
/// browser node, scheduler, or rendering lifecycle.
pub struct DiffFeatureProjection {
  sorted_changes : Array[@diff.DetailedLineRangeMapping]
  original_decorations : DiffPaneDecorations
  modified_decorations : DiffPaneDecorations
  original_overview : Array[DiffOverviewEntry]
  modified_overview : Array[DiffOverviewEntry]
  alignment_anchors : Array[@diff.LineRangeMapping]
}

///|
priv struct IndexedChange {
  source_index : Int
  change : @diff.DetailedLineRangeMapping
}

///|
fn compare_line_ranges(
  left : @base_common.LineRange,
  right : @base_common.LineRange,
) -> Int {
  let start_order = left.start_line_number - right.start_line_number
  if start_order != 0 {
    return start_order
  }
  left.end_line_number_exclusive - right.end_line_number_exclusive
}

///|
fn compare_mappings(
  left : @diff.LineRangeMapping,
  right : @diff.LineRangeMapping,
) -> Int {
  let original_order = compare_line_ranges(left.original, right.original)
  if original_order != 0 {
    return original_order
  }
  compare_line_ranges(left.modified, right.modified)
}

///|
fn compare_indexed_changes(left : IndexedChange, right : IndexedChange) -> Int {
  let mapping_order = compare_mappings(
    left.change.line_mapping(),
    right.change.line_mapping(),
  )
  if mapping_order != 0 {
    return mapping_order
  }
  // Array::sort_by is unstable. Preserve provider order for identical ranges.
  left.source_index - right.source_index
}

///|
priv struct IndexedAlignment {
  source_index : Int
  mapping : @diff.LineRangeMapping
}

///|
fn compare_indexed_alignments(
  left : IndexedAlignment,
  right : IndexedAlignment,
) -> Int {
  let mapping_order = compare_mappings(left.mapping, right.mapping)
  if mapping_order != 0 {
    return mapping_order
  }
  left.source_index - right.source_index
}

///|
fn sorted_changes(
  changes : Array[@diff.DetailedLineRangeMapping],
) -> Array[@diff.DetailedLineRangeMapping] {
  let indexed : Array[IndexedChange] = []
  for source_index, change in changes {
    indexed.push({ source_index, change })
  }
  indexed.sort_by(compare_indexed_changes)
  indexed.map(item => item.change)
}

///|
fn append_whole_line_range(
  target : Array[@base_common.Range],
  line_range : @base_common.LineRange,
  snapshot : @model.TextSnapshot,
) -> Unit {
  // An empty side denotes an insertion/deletion anchor, not a physical source
  // line. Likewise, an empty document's single cursor line is not changed
  // content and must not receive a whole-line decoration.
  if line_range.is_empty() || snapshot.get_value().is_empty() {
    return
  }
  let end_line = line_range.end_line_number_exclusive - 1
  target.push(
    @base_common.Range(
      line_range.start_line_number,
      1,
      end_line,
      snapshot.get_line_max_column(end_line),
    ),
  )
}

///|
fn append_inner_range(
  target : Array[@base_common.Range],
  range : @base_common.Range,
) -> Unit {
  if !range.is_empty() {
    // Range columns are already one-based UTF-16 coordinates. Copy the value
    // without converting through code points, bytes, or rendered columns.
    target.push(range)
  }
}

///|
fn sorted_alignment_anchors(
  changes : Array[@diff.DetailedLineRangeMapping],
  additional_alignments : Array[@diff.LineRangeMapping],
) -> Array[@diff.LineRangeMapping] {
  let indexed : Array[IndexedAlignment] = []
  for change in changes {
    indexed.push({
      source_index: indexed.length(),
      mapping: change.line_mapping(),
    })
  }
  for alignment in additional_alignments {
    indexed.push({ source_index: indexed.length(), mapping: alignment })
  }
  indexed.sort_by(compare_indexed_alignments)
  indexed.map(item => item.mapping)
}

///|
/// Derives all renderer-neutral diff feature inputs from one immutable result.
/// The input is expected to have passed DiffEditorViewModel validation.
pub fn DiffFeatureProjection::DiffFeatureProjection(
  document_diff : @diff.DocumentDiff,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
) -> DiffFeatureProjection {
  let changes = sorted_changes(document_diff.changes)
  let original_whole_line : Array[@base_common.Range] = []
  let modified_whole_line : Array[@base_common.Range] = []
  let original_inner : Array[@base_common.Range] = []
  let modified_inner : Array[@base_common.Range] = []
  let original_overview : Array[DiffOverviewEntry] = []
  let modified_overview : Array[DiffOverviewEntry] = []
  for change_index, change in changes {
    append_whole_line_range(original_whole_line, change.original, original)
    append_whole_line_range(modified_whole_line, change.modified, modified)
    if !change.original.is_empty() {
      original_overview.push({ change_index, range: change.original })
    }
    if !change.modified.is_empty() {
      modified_overview.push({ change_index, range: change.modified })
    }
    match change.inner_changes {
      Some(inner_changes) =>
        for inner_change in inner_changes {
          append_inner_range(original_inner, inner_change.original)
          append_inner_range(modified_inner, inner_change.modified)
        }
      None => ()
    }
  }
  {
    sorted_changes: changes,
    original_decorations: {
      whole_line: original_whole_line,
      inner: original_inner,
    },
    modified_decorations: {
      whole_line: modified_whole_line,
      inner: modified_inner,
    },
    original_overview,
    modified_overview,
    alignment_anchors: sorted_alignment_anchors(
      changes,
      document_diff.additional_alignments,
    ),
  }
}

///|
pub fn DiffFeatureProjection::change_count(self : DiffFeatureProjection) -> Int {
  self.sorted_changes.length()
}

///|
pub fn DiffFeatureProjection::change_at(
  self : DiffFeatureProjection,
  change_index : Int,
) -> @diff.DetailedLineRangeMapping? {
  if change_index < 0 || change_index >= self.sorted_changes.length() {
    None
  } else {
    Some(self.sorted_changes[change_index])
  }
}

///|
pub fn DiffFeatureProjection::original_decorations(
  self : DiffFeatureProjection,
) -> DiffPaneDecorations {
  self.original_decorations
}

///|
pub fn DiffFeatureProjection::modified_decorations(
  self : DiffFeatureProjection,
) -> DiffPaneDecorations {
  self.modified_decorations
}

///|
pub fn DiffFeatureProjection::original_overview_entries(
  self : DiffFeatureProjection,
) -> Array[DiffOverviewEntry] {
  self.original_overview.copy()
}

///|
pub fn DiffFeatureProjection::modified_overview_entries(
  self : DiffFeatureProjection,
) -> Array[DiffOverviewEntry] {
  self.modified_overview.copy()
}

///|
/// Geometry anchors contain every real change plus every additional alignment.
/// No other projection accessor observes additional_alignments.
pub fn DiffFeatureProjection::alignment_anchors(
  self : DiffFeatureProjection,
) -> Array[@diff.LineRangeMapping] {
  self.alignment_anchors.copy()
}

///|
pub fn DiffFeatureProjection::next_change(
  self : DiffFeatureProjection,
  current_change_index : Int?,
) -> DiffNavigationTarget? {
  let count = self.sorted_changes.length()
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
    change: self.sorted_changes[index],
  })
}

///|
pub fn DiffFeatureProjection::previous_change(
  self : DiffFeatureProjection,
  current_change_index : Int?,
) -> DiffNavigationTarget? {
  let count = self.sorted_changes.length()
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
    change: self.sorted_changes[index],
  })
}

///|
pub extend DiffNavigationTarget with Debug::{to_repr}

///|
pub extend DiffNavigationTarget with Eq::{equal, not_equal}

///|
pub extend DiffOverviewEntry with Debug::{to_repr}

///|
pub extend DiffOverviewEntry with Eq::{equal, not_equal}
