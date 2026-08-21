// The synchronous commit seam for one diff generation. Projection is produced
// before this seam; every visual feature commits in the same fixed order.

///|
fn pane_geometry_from_code_editor_parts(
  line_height : Double,
  model_line_heights : Array[@code_widget.CodeEditorModelLineHeight],
  foreign_zone_heights : Array[@code_widget.CodeEditorForeignZoneHeight],
  line_max_columns : Array[Int],
  viewport_width : Double,
) -> PaneGeometrySnapshot {
  PaneGeometrySnapshot(
    model_line_heights.length(),
    line_height,
    model_line_heights=model_line_heights.map(item => {
      (
        { line_number: item.line_number, height_in_px: item.height_in_px } :
        PaneModelLineHeight)
    }),
    foreign_zone_heights=foreign_zone_heights.map(item => {
      (
        {
          after_line_number: item.after_line_number,
          height_in_px: item.height_in_px,
        } : PaneForeignZoneHeight)
    }),
    line_max_columns~,
    viewport_width~,
  )
}

///|
fn pane_geometry_from_code_editor(
  snapshot : @code_widget.CodeEditorGeometrySnapshot,
) -> PaneGeometrySnapshot {
  pane_geometry_from_code_editor_parts(
    snapshot.line_height(),
    snapshot.model_line_heights(),
    snapshot.foreign_zone_heights(),
    snapshot.line_max_columns(),
    snapshot.scroll_content().viewport_width,
  )
}

///|
fn same_alignment_geometry(
  left : PaneGeometrySnapshot,
  right : PaneGeometrySnapshot,
) -> Bool {
  left.line_height == right.line_height &&
  left.viewport_width == right.viewport_width &&
  left.line_heights == right.line_heights &&
  left.line_max_columns == right.line_max_columns &&
  left.foreign_zone_heights == right.foreign_zone_heights &&
  left.cumulative_pixels == right.cumulative_pixels
}

///|
fn same_optional_alignment_geometry(
  left : PaneGeometrySnapshot?,
  right : PaneGeometrySnapshot?,
) -> Bool {
  match (left, right) {
    (None, None) => true
    (Some(left), Some(right)) => same_alignment_geometry(left, right)
    _ => false
  }
}

///|
fn alignment_geometry_pair_changed(
  original : PaneGeometrySnapshot?,
  modified : PaneGeometrySnapshot?,
  previous_original : PaneGeometrySnapshot?,
  previous_modified : PaneGeometrySnapshot?,
) -> Bool {
  !same_optional_alignment_geometry(original, previous_original) ||
  !same_optional_alignment_geometry(modified, previous_modified)
}

///|
fn commit_diff_reconcile_generation(
  generation : Int,
  apply_decorations : () -> Unit,
  apply_original_view_zones : (Int) -> Unit,
  apply_modified_view_zones : (Int) -> Unit,
  restore_stable_viewports : () -> Unit,
  apply_overview_ruler : (Int) -> Unit,
) -> Unit {
  apply_decorations()
  apply_original_view_zones(generation)
  apply_modified_view_zones(generation)
  restore_stable_viewports()
  apply_overview_ruler(generation)
}
