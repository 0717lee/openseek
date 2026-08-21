// Diff-specific projection into the generic CodeEditorWidget overview-ruler
// contract. Every range is expressed in modified-model coordinates because
// the managed ruler and pointer navigation both belong to that kernel.

///|
let diff_overview_removed_color = "var(--vscode-diffEditorOverview-removedForeground, var(--vscode-diffEditor-removedLineBackground, rgba(255, 0, 0, 0.6)))"

///|
let diff_overview_inserted_color = "var(--vscode-diffEditorOverview-insertedForeground, var(--vscode-diffEditor-insertedLineBackground, rgba(155, 185, 85, 0.6)))"

///|
fn modified_overview_range(
  change : @diff.DetailedLineRangeMapping,
  modified_line_count : Int,
) -> @base_common.LineRange {
  if !change.modified.is_empty() {
    return change.modified
  }
  // Deletion-only changes have no physical modified line. Give their removed
  // lane a one-line anchor in the modified document so the generic ruler can
  // use the same geometry and reveal API as every other entry.
  let line_count = modified_line_count.max(1)
  let anchor = change.modified.start_line_number.clamp(min=1, max=line_count)
  @base_common.LineRange(anchor, anchor + 1)
}

///|
fn diff_overview_ruler_entries(
  projection : DiffFeatureProjection,
  modified_line_count : Int,
) -> Array[@code_widget.CodeEditorOverviewRulerEntry] {
  let entries : Array[@code_widget.CodeEditorOverviewRulerEntry] = []
  for entry in projection.original_overview_entries() {
    match projection.change_at(entry.change_index) {
      Some(change) =>
        entries.push({
          id: entry.change_index,
          range: modified_overview_range(change, modified_line_count),
          color: diff_overview_removed_color,
          lane: Left,
        })
      None => ()
    }
  }
  for entry in projection.modified_overview_entries() {
    entries.push({
      id: entry.change_index,
      range: entry.range,
      color: diff_overview_inserted_color,
      lane: Right,
    })
  }
  entries
}
