// VS Code renders original and modified overview data against their own
// editor/model coordinates. Keeping the two streams separate avoids inventing
// a modified-side anchor for deletion-only changes.

///|
let diff_overview_removed_color = "var(--vscode-diffEditorOverview-removedForeground, var(--vscode-diffEditor-removedLineBackground, rgba(255, 0, 0, 0.6)))"

///|
let diff_overview_inserted_color = "var(--vscode-diffEditorOverview-insertedForeground, var(--vscode-diffEditor-insertedLineBackground, rgba(155, 185, 85, 0.6)))"

///|
fn original_diff_overview_ruler_entries(
  diff_state : DiffState,
) -> Array[@code_widget.CodeEditorOverviewRulerEntry] {
  let entries : Array[@code_widget.CodeEditorOverviewRulerEntry] = []
  for change_index, mapping in diff_state.mappings {
    let range = mapping.line_range_mapping.original
    if !range.is_empty() {
      entries.push({
        id: change_index,
        range,
        color: diff_overview_removed_color,
        lane: Full,
      })
    }
  }
  entries
}

///|
fn modified_diff_overview_ruler_entries(
  diff_state : DiffState,
) -> Array[@code_widget.CodeEditorOverviewRulerEntry] {
  let entries : Array[@code_widget.CodeEditorOverviewRulerEntry] = []
  for change_index, mapping in diff_state.mappings {
    let range = mapping.line_range_mapping.modified
    if !range.is_empty() {
      entries.push({
        id: change_index,
        range,
        color: diff_overview_inserted_color,
        lane: Full,
      })
    }
  }
  entries
}
