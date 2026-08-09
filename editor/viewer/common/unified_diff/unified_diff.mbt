///|
/// One line in a unified diff hunk.
pub(all) enum UnifiedDiffLineKind {
  Context
  Deletion
  Addition
} derive(Eq, Debug)

///|
/// A line carries the number for each side on which it exists. Context lines
/// have both, deletions only the original number, and additions only the
/// modified number.
pub(all) struct UnifiedDiffLine {
  kind : UnifiedDiffLineKind
  original_line_number : Int?
  modified_line_number : Int?
  text : String
} derive(Eq, Debug)

///|
/// One context-bounded unified diff hunk. Start numbers follow unified-diff
/// notation: an empty side is anchored at the preceding line (zero at the
/// beginning of a file).
pub(all) struct UnifiedDiffHunk {
  original_start_line_number : Int
  original_line_count : Int
  modified_start_line_number : Int
  modified_line_count : Int
  lines : Array[UnifiedDiffLine]
} derive(Eq, Debug)

///|
/// One algorithm-neutral line change. Ranges are 1-based and half-open;
/// an empty original range is an insertion and an empty modified range is a
/// deletion. Algorithms must return changes in document order.
pub(all) struct UnifiedDiffChange {
  original_start_line_number : Int
  original_end_line_number_exclusive : Int
  modified_start_line_number : Int
  modified_end_line_number_exclusive : Int
} derive(Eq, Debug)

///|
/// Options that belong to line matching rather than hunk presentation.
pub(all) struct UnifiedDiffAlgorithmOptions {
  ignore_trim_whitespace : Bool
  max_computation_time_ms : Int
} derive(Eq, Debug)

///|
/// Replaceable line-matching boundary. The unified-hunk model depends only on
/// `UnifiedDiffChange`, so a future algorithm needs only this small adapter.
pub struct UnifiedDiffAlgorithm {
  compute_changes_callback : (
    Array[String],
    Array[String],
    UnifiedDiffAlgorithmOptions,
  ) -> Array[UnifiedDiffChange]
}

///|
pub fn UnifiedDiffAlgorithm::UnifiedDiffAlgorithm(
  compute_changes~ : (Array[String], Array[String], UnifiedDiffAlgorithmOptions) -> Array[
    UnifiedDiffChange,
  ],
) -> UnifiedDiffAlgorithm {
  { compute_changes_callback: compute_changes }
}

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
/// The current adapter uses the editor's existing diff engine, keeping full
/// and quick diff aligned without coupling the hunk builder to that engine.
pub fn default_unified_diff_algorithm() -> UnifiedDiffAlgorithm {
  UnifiedDiffAlgorithm(compute_changes=(original_lines, modified_lines, options) => {
    @diff.get_default().compute_diff(original_lines, modified_lines, {
      ignore_trim_whitespace: options.ignore_trim_whitespace,
      max_computation_time_ms: options.max_computation_time_ms,
      compute_moves: false,
    }).changes.map(change => {
      original_start_line_number: change.original.start_line_number,
      original_end_line_number_exclusive: change.original.end_line_number_exclusive,
      modified_start_line_number: change.modified.start_line_number,
      modified_end_line_number_exclusive: change.modified.end_line_number_exclusive,
    })
  })
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

///|
/// Compute context-bounded unified diff hunks from two arrays of lines.
///
/// Both `[]` and the editor's `[""]` representation are treated as an empty
/// document before invoking the algorithm.
///
/// By default, line mapping comes from the editor's existing diff engine so a
/// future full-diff view and the current quick-diff gutter agree. Pass an
/// alternate `algorithm` to replace matching without changing hunk rendering.
pub fn compute_unified_diff(
  original_lines : Array[String],
  modified_lines : Array[String],
  context_lines? : Int = 3,
  ignore_trim_whitespace? : Bool = false,
  max_computation_time_ms? : Int = 1000,
  algorithm? : UnifiedDiffAlgorithm = default_unified_diff_algorithm(),
) -> Array[UnifiedDiffHunk] {
  let context_lines = context_lines.max(0)
  let original_lines = canonical_diff_lines(original_lines)
  let modified_lines = canonical_diff_lines(modified_lines)
  let changes = algorithm.compute_changes(original_lines, modified_lines, {
    ignore_trim_whitespace,
    max_computation_time_ms,
  })
  hunk_windows(
    changes,
    original_lines.length(),
    modified_lines.length(),
    context_lines,
  ).map(window => window.to_hunk(original_lines, modified_lines))
}
