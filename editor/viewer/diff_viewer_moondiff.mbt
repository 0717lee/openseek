///|
/// The selected algorithm plus the line mappings consumed by the existing
/// decoration/alignment renderer. `fell_back` is true only when a requested
/// moondiff calculation was rejected and the standard editor diff was used.
priv struct DiffChangeCalculation {
  changes : Array[DiffLineChange]
  effective_mode : DiffViewerMode
  fell_back : Bool
}

///|
fn DiffEditorModel::supports_moondiff(self : DiffEditorModel) -> Bool {
  self.modified.uri.path.to_lower().has_suffix(".mbt")
}

///|
fn standard_diff_changes(
  original_lines : Array[String],
  modified_lines : Array[String],
) -> Array[DiffLineChange] {
  let diff = @diff.get_default().compute_diff(original_lines, modified_lines, {
    ignore_trim_whitespace: false,
    max_computation_time_ms: 5000,
    compute_moves: false,
  })
  diff.changes.map(change => {
    let original_inner_changed : Array[@base_common.Range] = []
    let modified_inner_changed : Array[@base_common.Range] = []
    match change.get_inner_changes() {
      Some(inner_changes) =>
        for inner_change in inner_changes {
          let (original, modified) = inner_change
          original_inner_changed.push(original)
          modified_inner_changed.push(modified)
        }
      None => ()
    }
    {
      original: change.original,
      modified: change.modified,
      original_inner_changed,
      modified_inner_changed,
    }
  })
}

///|
fn calculate_diff_changes(
  requested_mode : DiffViewerMode,
  specialized_available : Bool,
  original_lines : Array[String],
  modified_lines : Array[String],
  original_source : String,
  modified_source : String,
) -> DiffChangeCalculation {
  if !specialized_available || requested_mode is StandardDiff {
    return {
      changes: standard_diff_changes(original_lines, modified_lines),
      effective_mode: StandardDiff,
      fell_back: false,
    }
  }
  match
    moondiff_changes(
      requested_mode, original_lines, modified_lines, original_source, modified_source,
    ) {
    Some(changes) =>
      { changes, effective_mode: requested_mode, fell_back: false }
    None =>
      {
        changes: standard_diff_changes(original_lines, modified_lines),
        effective_mode: StandardDiff,
        fell_back: true,
      }
  }
}

///|
fn moondiff_changes(
  mode : DiffViewerMode,
  original_lines : Array[String],
  modified_lines : Array[String],
  original_source : String,
  modified_source : String,
) -> Array[DiffLineChange]? {
  let document = match mode {
    StandardDiff => return None
    TokenDiff =>
      @tokdiff.diff(
        old=original_lines,
        new=modified_lines,
        context=0,
        line_cleanup=true,
      )
    TreeDiff => {
      let result = @mbtdiff.diff(
        original_source,
        modified_source,
        options=@mbtdiff.DiffOptions::new(context_lines=0),
      )
      // moondiff can internally degrade a failed tree calculation to its
      // lexical renderer. The DiffViewer contract is stricter: any typed
      // parse/graph/computation fallback returns to the editor's standard
      // algorithm instead.
      if result.has_fallback() {
        return None
      }
      result.document()
    }
  }
  guard moondiff_document_changes(document, original_lines, modified_lines)
    is Some(changes) else {
    return None
  }
  // Token diff has no typed error channel. Treat a non-identical pair with an
  // empty or malformed renderer-neutral document as a failed calculation.
  if mode is TokenDiff &&
    original_source != modified_source &&
    changes.is_empty() {
    None
  } else {
    Some(changes)
  }
}

///|
fn valid_moondiff_hunk_range(start : Int, len : Int, total : Int) -> Bool {
  start >= 0 && len >= 0 && start <= total && len <= total - start
}

///|
fn valid_moondiff_line(
  line : @tokdiff.DiffLine,
  expected_index : Int,
  source : Array[String],
) -> Bool {
  line.index == expected_index &&
  expected_index >= 0 &&
  expected_index < source.length() &&
  line.text() == source[expected_index]
}

///|
fn moondiff_inner_ranges(line : @tokdiff.DiffLine) -> Array[@base_common.Range] {
  let ranges : Array[@base_common.Range] = []
  let mut column = 1
  for segment in line.segments {
    let end_column = column + segment.text.length()
    if segment.kind is @tokdiff.DiffSegmentKind::Changed && end_column > column {
      ranges.push(
        @base_common.Range(line.index + 1, column, line.index + 1, end_column),
      )
    }
    column = end_column
  }
  ranges
}

///|
fn moondiff_paired_change(
  original : @tokdiff.DiffLine,
  modified : @tokdiff.DiffLine,
) -> DiffLineChange {
  {
    original: @base_common.LineRange(original.index + 1, original.index + 2),
    modified: @base_common.LineRange(modified.index + 1, modified.index + 2),
    original_inner_changed: moondiff_inner_ranges(original),
    modified_inner_changed: moondiff_inner_ranges(modified),
  }
}

///|
fn moondiff_old_only_change(
  original : @tokdiff.DiffLine,
  modified_cursor : Int,
) -> DiffLineChange {
  {
    original: @base_common.LineRange(original.index + 1, original.index + 2),
    modified: @base_common.LineRange(modified_cursor + 1, modified_cursor + 1),
    original_inner_changed: moondiff_inner_ranges(original),
    modified_inner_changed: [],
  }
}

///|
fn moondiff_new_only_change(
  modified : @tokdiff.DiffLine,
  original_cursor : Int,
) -> DiffLineChange {
  {
    original: @base_common.LineRange(original_cursor + 1, original_cursor + 1),
    modified: @base_common.LineRange(modified.index + 1, modified.index + 2),
    original_inner_changed: [],
    modified_inner_changed: moondiff_inner_ranges(modified),
  }
}

///|
fn append_moondiff_rows(
  rows : Array[@tokdiff.DiffRow],
  render_changes : Bool,
  original_lines : Array[String],
  modified_lines : Array[String],
  original_cursor : Int,
  modified_cursor : Int,
  changes : Array[DiffLineChange],
) -> (Int, Int)? {
  let mut old_cursor = original_cursor
  let mut new_cursor = modified_cursor
  for row in rows {
    match row {
      @tokdiff.DiffRow::Paired(original, modified) => {
        if !valid_moondiff_line(original, old_cursor, original_lines) ||
          !valid_moondiff_line(modified, new_cursor, modified_lines) {
          return None
        }
        if render_changes {
          changes.push(moondiff_paired_change(original, modified))
        }
        old_cursor += 1
        new_cursor += 1
      }
      @tokdiff.DiffRow::OldOnly(original) => {
        if !valid_moondiff_line(original, old_cursor, original_lines) {
          return None
        }
        if render_changes {
          changes.push(moondiff_old_only_change(original, new_cursor))
        }
        old_cursor += 1
      }
      @tokdiff.DiffRow::NewOnly(modified) => {
        if !valid_moondiff_line(modified, new_cursor, modified_lines) {
          return None
        }
        if render_changes {
          changes.push(moondiff_new_only_change(modified, old_cursor))
        }
        new_cursor += 1
      }
    }
  }
  Some((old_cursor, new_cursor))
}

///|
/// Validate moondiff's renderer-neutral document against the exact models and
/// adapt its zero-based aligned rows to the Viewer's one-based line/range
/// contract. Validation is also Token mode's failure boundary because its
/// public calculation API is deliberately total and has no typed error value.
fn moondiff_document_changes(
  document : @tokdiff.DiffDocument,
  original_lines : Array[String],
  modified_lines : Array[String],
) -> Array[DiffLineChange]? {
  let changes : Array[DiffLineChange] = []
  for hunk in document.hunks {
    if !valid_moondiff_hunk_range(
        hunk.old_start,
        hunk.old_len,
        original_lines.length(),
      ) ||
      !valid_moondiff_hunk_range(
        hunk.new_start,
        hunk.new_len,
        modified_lines.length(),
      ) {
      return None
    }
    let mut old_cursor = hunk.old_start
    let mut new_cursor = hunk.new_start
    for block in hunk.blocks {
      match block {
        @tokdiff.DiffBlock::ContextBlock(lines) =>
          for line in lines {
            if line.old_index != old_cursor ||
              line.new_index != new_cursor ||
              old_cursor >= original_lines.length() ||
              new_cursor >= modified_lines.length() ||
              line.text != original_lines[old_cursor] ||
              line.text != modified_lines[new_cursor] {
              return None
            }
            old_cursor += 1
            new_cursor += 1
          }
        @tokdiff.DiffBlock::ChangeBlock(rows) =>
          match
            append_moondiff_rows(
              rows, true, original_lines, modified_lines, old_cursor, new_cursor,
              changes,
            ) {
            Some((next_old, next_new)) => {
              old_cursor = next_old
              new_cursor = next_new
            }
            None => return None
          }
        @tokdiff.DiffBlock::IgnoredBlock(rows) =>
          match
            append_moondiff_rows(
              rows, false, original_lines, modified_lines, old_cursor, new_cursor,
              changes,
            ) {
            Some((next_old, next_new)) => {
              old_cursor = next_old
              new_cursor = next_new
            }
            None => return None
          }
      }
    }
    if old_cursor != hunk.old_start + hunk.old_len ||
      new_cursor != hunk.new_start + hunk.new_len {
      return None
    }
  }
  Some(changes)
}
