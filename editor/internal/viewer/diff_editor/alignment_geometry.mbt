// Pure pixel geometry for diff-pane alignment. The pane producer captures
// actual model-line heights and foreign zone heights after excluding all
// managed alignment zones. This engine only compares immutable numeric axes.

///|
/// An exact rendered height override for one model line. Wrapped lines use a
/// height greater than `line_height`; hidden lines are represented separately
/// and always resolve to zero height.
pub(all) struct PaneModelLineHeight {
  line_number : Int
  height_in_px : Double
} derive(Eq, Debug)

///|
/// Extra geometry after a model line. `after_line_number == 0` represents top
/// padding before line 1. The snapshot producer must omit zones owned by the
/// current alignment transaction.
pub(all) struct PaneForeignZoneHeight {
  after_line_number : Int
  height_in_px : Double
} derive(Eq, Debug)

///|
/// Immutable geometry for one pane and one render generation. The cumulative
/// axis stores pixels after each model-line boundary, including foreign zones.
pub struct PaneGeometrySnapshot {
  line_height : Double
  viewport_width : Double
  line_heights : Array[Double]
  line_max_columns : Array[Int]?
  foreign_zone_heights : Array[PaneForeignZoneHeight]
  cumulative_pixels : Array[Double]
}

///|
fn normalized_foreign_zone_heights(
  line_count : Int,
  zones : Array[PaneForeignZoneHeight],
) -> Array[PaneForeignZoneHeight] {
  let heights = Array::make(line_count + 1, 0.0)
  for zone in zones {
    if zone.after_line_number >= 0 &&
      zone.after_line_number <= line_count &&
      zone.height_in_px > 0.0 {
      heights[zone.after_line_number] += zone.height_in_px
    }
  }
  let result : Array[PaneForeignZoneHeight] = []
  for boundary in 0..<=line_count {
    if heights[boundary] > 0.0 {
      result.push({
        after_line_number: boundary,
        height_in_px: heights[boundary],
      })
    }
  }
  result
}

///|
/// Builds a pane axis. `model_line_heights` are exact heights, not deltas;
/// `hidden_lines` are applied last so a hidden wrapped line still contributes
/// zero pixels. `line_max_columns` is optional and only enables the secondary
/// synchronization point after a character-level change.
pub fn PaneGeometrySnapshot::PaneGeometrySnapshot(
  line_count : Int,
  line_height : Double,
  model_line_heights? : Array[PaneModelLineHeight] = [],
  hidden_lines? : Array[@base_common.LineRange] = [],
  foreign_zone_heights? : Array[PaneForeignZoneHeight] = [],
  line_max_columns? : Array[Int],
  viewport_width? : Double = 0.0,
) -> PaneGeometrySnapshot {
  let line_count = line_count.max(0)
  let line_height = line_height.max(0.0)
  let line_heights = Array::make(line_count, line_height)
  for item in model_line_heights {
    if item.line_number >= 1 && item.line_number <= line_count {
      line_heights[item.line_number - 1] = item.height_in_px.max(0.0)
    }
  }
  for hidden in hidden_lines {
    let start = hidden.start_line_number.max(1)
    let end_exclusive = hidden.end_line_number_exclusive.min(line_count + 1)
    for line_number in start..<end_exclusive {
      line_heights[line_number - 1] = 0.0
    }
  }
  let foreign_zone_heights = normalized_foreign_zone_heights(
    line_count, foreign_zone_heights,
  )
  let zone_heights = Array::make(line_count + 1, 0.0)
  for zone in foreign_zone_heights {
    zone_heights[zone.after_line_number] = zone.height_in_px
  }
  let cumulative_pixels = Array::make(line_count + 1, 0.0)
  cumulative_pixels[0] = zone_heights[0]
  for line_number in 1..<=line_count {
    cumulative_pixels[line_number] = cumulative_pixels[line_number - 1] +
      line_heights[line_number - 1] +
      zone_heights[line_number]
  }
  {
    line_height,
    viewport_width: viewport_width.max(0.0),
    line_heights,
    line_max_columns: line_max_columns.map(columns => columns.copy()),
    foreign_zone_heights,
    cumulative_pixels,
  }
}

///|
pub fn PaneGeometrySnapshot::viewport_width(
  self : PaneGeometrySnapshot,
) -> Double {
  self.viewport_width
}

///|
pub fn PaneGeometrySnapshot::line_height(self : PaneGeometrySnapshot) -> Double {
  self.line_height
}

///|
pub fn PaneGeometrySnapshot::line_count(self : PaneGeometrySnapshot) -> Int {
  self.line_heights.length()
}

///|
pub fn PaneGeometrySnapshot::content_height(
  self : PaneGeometrySnapshot,
) -> Double {
  self.cumulative_pixels[self.cumulative_pixels.length() - 1]
}

///|
pub fn PaneGeometrySnapshot::foreign_zone_heights(
  self : PaneGeometrySnapshot,
) -> Array[PaneForeignZoneHeight] {
  self.foreign_zone_heights.copy()
}

///|
fn PaneGeometrySnapshot::pixels_after_line(
  self : PaneGeometrySnapshot,
  after_line_number : Int,
) -> Double {
  let boundary = after_line_number.clamp(min=0, max=self.line_count())
  self.cumulative_pixels[boundary]
}

///|
fn PaneGeometrySnapshot::max_column(
  self : PaneGeometrySnapshot,
  line_number : Int,
) -> Int? {
  guard self.line_max_columns is Some(columns) else { return None }
  if line_number < 1 || line_number > columns.length() {
    None
  } else {
    Some(columns[line_number - 1])
  }
}

///|
fn PaneGeometrySnapshot::has_top_foreign_zone(
  self : PaneGeometrySnapshot,
) -> Bool {
  !self.foreign_zone_heights.is_empty() &&
  self.foreign_zone_heights[0].after_line_number == 0
}

///|
/// A zone specification applied by the owning widget. A zero anchor places a
/// spacer before line 1, matching the editor's managed-zone coordinate system.
pub(all) struct ManagedAlignmentSpacer {
  after_line_number : Int
  height_in_px : Double
} derive(Eq, Debug)

///|
pub struct ManagedAlignmentSpacers {
  original : Array[ManagedAlignmentSpacer]
  modified : Array[ManagedAlignmentSpacer]
}

///|
pub fn ManagedAlignmentSpacers::original(
  self : ManagedAlignmentSpacers,
) -> Array[ManagedAlignmentSpacer] {
  self.original.copy()
}

///|
pub fn ManagedAlignmentSpacers::modified(
  self : ManagedAlignmentSpacers,
) -> Array[ManagedAlignmentSpacer] {
  self.modified.copy()
}

///|
fn append_managed_spacer(
  target : Array[ManagedAlignmentSpacer],
  after_line_number : Int,
  height_in_px : Double,
) -> Unit {
  if height_in_px <= 0.01 {
    return
  }
  if !target.is_empty() &&
    target[target.length() - 1].after_line_number == after_line_number {
    let previous = target[target.length() - 1]
    target[target.length() - 1] = {
      after_line_number,
      height_in_px: previous.height_in_px + height_in_px,
    }
  } else {
    target.push({ after_line_number, height_in_px })
  }
}

///|
fn canonical_change_for_anchor(
  projection : DiffFeatureProjection,
  anchor : @diff.LineRangeMapping,
) -> @diff.DetailedLineRangeMapping? {
  for index in 0..<projection.change_count() {
    guard projection.change_at(index) is Some(change) else { continue }
    if change.line_mapping() == anchor {
      return Some(change)
    }
  }
  None
}

///|
priv struct AlignmentBoundaryState {
  mut original_boundary : Int
  mut modified_boundary : Int
  mut original_pixels : Double
  mut modified_pixels : Double
  mut original_event_index : Int
  mut modified_event_index : Int
}

///|
fn alignment_event_boundaries(geometry : PaneGeometrySnapshot) -> Array[Int] {
  let boundaries : Array[Int] = []
  if geometry.has_top_foreign_zone() {
    boundaries.push(0)
  }
  // Every model-line boundary is a synchronization candidate. This makes
  // arbitrary wrapping, hidden lines, and even differing base line heights
  // exact without storing callbacks in the geometry snapshot.
  for line_number in 1..<=geometry.line_count() {
    boundaries.push(line_number)
  }
  boundaries
}

///|
fn drop_consumed_events(
  state : AlignmentBoundaryState,
  original_events : Array[Int],
  modified_events : Array[Int],
) -> Unit {
  while state.original_event_index < original_events.length() &&
        original_events[state.original_event_index] <= state.original_boundary {
    state.original_event_index += 1
  }
  while state.modified_event_index < modified_events.length() &&
        modified_events[state.modified_event_index] <= state.modified_boundary {
    state.modified_event_index += 1
  }
}

///|
/// Computes managed spacers from the projection's canonical changes and
/// geometry-only anchors. Additional alignments participate because they are
/// present in `alignment_anchors`, but they have no path to visual features.
pub fn compute_managed_alignment_spacers(
  projection : DiffFeatureProjection,
  original_geometry : PaneGeometrySnapshot,
  modified_geometry : PaneGeometrySnapshot,
  inner_hunk_alignment? : Bool = true,
) -> ManagedAlignmentSpacers {
  let original_spacers : Array[ManagedAlignmentSpacer] = []
  let modified_spacers : Array[ManagedAlignmentSpacer] = []
  let original_events = alignment_event_boundaries(original_geometry)
  let modified_events = alignment_event_boundaries(modified_geometry)
  let state : AlignmentBoundaryState = {
    original_boundary: 0,
    modified_boundary: 0,
    original_pixels: 0.0,
    modified_pixels: 0.0,
    original_event_index: 0,
    modified_event_index: 0,
  }

  let emit_alignment = fn(original_boundary : Int, modified_boundary : Int) {
    if original_boundary < state.original_boundary ||
      modified_boundary < state.modified_boundary ||
      original_boundary > original_geometry.line_count() ||
      modified_boundary > modified_geometry.line_count() {
      return
    }
    let original_end_pixels = original_geometry.pixels_after_line(
      original_boundary,
    )
    let modified_end_pixels = modified_geometry.pixels_after_line(
      modified_boundary,
    )
    let original_height = original_end_pixels - state.original_pixels
    let modified_height = modified_end_pixels - state.modified_pixels
    let delta = modified_height - original_height
    if delta > 0.01 {
      append_managed_spacer(original_spacers, original_boundary, delta)
    } else if delta < -0.01 {
      append_managed_spacer(modified_spacers, modified_boundary, -delta)
    }
    state.original_boundary = original_boundary
    state.modified_boundary = modified_boundary
    state.original_pixels = original_end_pixels
    state.modified_pixels = modified_end_pixels
  }

  let handle_outside_anchors = fn(
    until_original_boundary : Int,
    until_modified_boundary : Int,
  ) {
    while true {
      let original_next = if state.original_event_index <
        original_events.length() &&
        original_events[state.original_event_index] <= until_original_boundary {
        Some(original_events[state.original_event_index])
      } else {
        None
      }
      let modified_next = if state.modified_event_index <
        modified_events.length() &&
        modified_events[state.modified_event_index] <= until_modified_boundary {
        Some(modified_events[state.modified_event_index])
      } else {
        None
      }
      if original_next is None && modified_next is None {
        break
      }
      let original_distance = match original_next {
        Some(boundary) => boundary - state.original_boundary
        None => 2147483647
      }
      let modified_distance = match modified_next {
        Some(boundary) => boundary - state.modified_boundary
        None => 2147483647
      }
      let (original_boundary, modified_boundary) = if original_distance <
        modified_distance {
        guard original_next is Some(boundary) else { break }
        state.original_event_index += 1
        (boundary, state.modified_boundary + original_distance)
      } else if original_distance > modified_distance {
        guard modified_next is Some(boundary) else { break }
        state.modified_event_index += 1
        (state.original_boundary + modified_distance, boundary)
      } else {
        guard (original_next, modified_next) is (Some(original), Some(modified)) else {
          break
        }
        state.original_event_index += 1
        state.modified_event_index += 1
        (original, modified)
      }
      emit_alignment(original_boundary, modified_boundary)
    }
  }

  for anchor in projection.alignment_anchors() {
    let original_start_boundary = anchor.original.start_line_number - 1
    let modified_start_boundary = anchor.modified.start_line_number - 1
    let original_end_boundary = anchor.original.end_line_number_exclusive - 1
    let modified_end_boundary = anchor.modified.end_line_number_exclusive - 1
    if original_start_boundary < state.original_boundary ||
      modified_start_boundary < state.modified_boundary ||
      original_end_boundary < original_start_boundary ||
      modified_end_boundary < modified_start_boundary {
      continue
    }
    handle_outside_anchors(original_start_boundary, modified_start_boundary)
    // If sparse geometry had no event at the start, establish the unchanged
    // prefix checkpoint before entering the hunk/alignment range.
    emit_alignment(original_start_boundary, modified_start_boundary)
    if inner_hunk_alignment {
      match canonical_change_for_anchor(projection, anchor) {
        Some(change) =>
          match change.inner_changes {
            Some(inner_changes) =>
              for inner in inner_changes {
                if inner.original.start_column > 1 &&
                  inner.modified.start_column > 1 {
                  emit_alignment(
                    inner.original.start_line_number - 1,
                    inner.modified.start_line_number - 1,
                  )
                }
                match
                  original_geometry.max_column(inner.original.end_line_number) {
                  Some(max_column) if inner.original.end_column < max_column =>
                    emit_alignment(
                      inner.original.end_line_number - 1,
                      inner.modified.end_line_number - 1,
                    )
                  _ => ()
                }
              }
            None => ()
          }
        None => ()
      }
    }
    emit_alignment(original_end_boundary, modified_end_boundary)
    drop_consumed_events(state, original_events, modified_events)
  }

  // The final model-line boundary is handled by the same geometry transaction
  // as every other unchanged boundary. A wrapped/hidden/foreign-zone delta on
  // the final line therefore produces an ordinary managed spacer, not a
  // residual content-height correction.
  handle_outside_anchors(
    original_geometry.line_count(),
    modified_geometry.line_count(),
  )
  emit_alignment(original_geometry.line_count(), modified_geometry.line_count())
  { original: original_spacers, modified: modified_spacers }
}

///|
pub extend ManagedAlignmentSpacer with Debug::{to_repr}

///|
pub extend ManagedAlignmentSpacer with Eq::{equal, not_equal}

///|
pub extend PaneForeignZoneHeight with Debug::{to_repr}

///|
pub extend PaneForeignZoneHeight with Eq::{equal, not_equal}

///|
pub extend PaneModelLineHeight with Debug::{to_repr}

///|
pub extend PaneModelLineHeight with Eq::{equal, not_equal}
