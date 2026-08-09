///|
fn UnifiedDiffAlgorithm::compute_changes(
  self : UnifiedDiffAlgorithm,
  original_lines : Array[String],
  modified_lines : Array[String],
  options : UnifiedDiffAlgorithmOptions,
) -> Array[UnifiedDiffChange] {
  (self.compute_changes_callback)(original_lines, modified_lines, options)
}

///|
priv struct HunkWindow {
  original_start : Int
  mut original_end_exclusive : Int
  modified_start : Int
  mut modified_end_exclusive : Int
  changes : Array[UnifiedDiffChange]
}

///|
fn hunk_windows(
  changes : Array[UnifiedDiffChange],
  original_line_count : Int,
  modified_line_count : Int,
  context_lines : Int,
) -> Array[HunkWindow] {
  let windows : Array[HunkWindow] = []
  for change in changes {
    let original_limit = original_line_count + 1
    let modified_limit = modified_line_count + 1
    let original_start = change.original_start_line_number -
      context_lines.min(change.original_start_line_number - 1)
    let original_end_exclusive = change.original_end_line_number_exclusive +
      context_lines.min(
        original_limit - change.original_end_line_number_exclusive,
      )
    let modified_start = change.modified_start_line_number -
      context_lines.min(change.modified_start_line_number - 1)
    let modified_end_exclusive = change.modified_end_line_number_exclusive +
      context_lines.min(
        modified_limit - change.modified_end_line_number_exclusive,
      )
    match windows.last() {
      Some(previous) if original_start <= previous.original_end_exclusive &&
        modified_start <= previous.modified_end_exclusive => {
        previous.original_end_exclusive = previous.original_end_exclusive.max(
          original_end_exclusive,
        )
        previous.modified_end_exclusive = previous.modified_end_exclusive.max(
          modified_end_exclusive,
        )
        previous.changes.push(change)
      }
      _ =>
        windows.push({
          original_start,
          original_end_exclusive,
          modified_start,
          modified_end_exclusive,
          changes: [change],
        })
    }
  }
  windows
}

///|
fn HunkWindow::to_hunk(
  self : HunkWindow,
  original_lines : Array[String],
  modified_lines : Array[String],
) -> UnifiedDiffHunk {
  let lines : Array[UnifiedDiffLine] = []
  let mut original_line = self.original_start
  let mut modified_line = self.modified_start
  for change in self.changes {
    while original_line < change.original_start_line_number &&
          modified_line < change.modified_start_line_number {
      lines.push({
        kind: Context,
        original_line_number: Some(original_line),
        modified_line_number: Some(modified_line),
        text: modified_lines[modified_line - 1],
      })
      original_line += 1
      modified_line += 1
    }
    while original_line < change.original_end_line_number_exclusive {
      lines.push({
        kind: Deletion,
        original_line_number: Some(original_line),
        modified_line_number: None,
        text: original_lines[original_line - 1],
      })
      original_line += 1
    }
    while modified_line < change.modified_end_line_number_exclusive {
      lines.push({
        kind: Addition,
        original_line_number: None,
        modified_line_number: Some(modified_line),
        text: modified_lines[modified_line - 1],
      })
      modified_line += 1
    }
  }
  while original_line < self.original_end_exclusive &&
        modified_line < self.modified_end_exclusive {
    lines.push({
      kind: Context,
      original_line_number: Some(original_line),
      modified_line_number: Some(modified_line),
      text: modified_lines[modified_line - 1],
    })
    original_line += 1
    modified_line += 1
  }
  let original_line_count = self.original_end_exclusive - self.original_start
  let modified_line_count = self.modified_end_exclusive - self.modified_start
  {
    original_start_line_number: if original_line_count == 0 {
      self.original_start - 1
    } else {
      self.original_start
    },
    original_line_count,
    modified_start_line_number: if modified_line_count == 0 {
      self.modified_start - 1
    } else {
      self.modified_start
    },
    modified_line_count,
    lines,
  }
}

///|
fn canonical_diff_lines(lines : Array[String]) -> Array[String] {
  if lines.length() == 1 && lines[0].is_empty() {
    []
  } else {
    lines
  }
}
