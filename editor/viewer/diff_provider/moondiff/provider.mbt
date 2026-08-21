///|
/// Algorithms offered by the optional MoonBit-aware provider. Core remains a
/// first-class choice so one host-owned toolbar can keep a single provider
/// instance while switching modes.
pub(all) enum MoonDiffMode {
  Core
  Token
  Tree
} derive(Eq, Debug)

///|
/// The result mode is host-visible product state. Tree can legitimately
/// degrade to Token, while invalid specialized output degrades to Core.
pub(all) struct MoonDiffStatus {
  requested : MoonDiffMode
  effective : MoonDiffMode
  fell_back : Bool
} derive(Eq, Debug)

///|
/// Optional synchronous provider used only by the desktop review host. The
/// diff editor core depends exclusively on DocumentDiffProvider and therefore
/// has no MoonDiff modes, controls, or fallback policy.
pub struct MoonDocumentDiffProvider {
  mut mode : MoonDiffMode
  mut ignore_comments : Bool
  mut status : MoonDiffStatus
  did_change : @base_common.Emitter[Unit]
  mut disposed : Bool
}

///|
pub fn MoonDocumentDiffProvider::MoonDocumentDiffProvider(
  mode? : MoonDiffMode = Core,
  ignore_comments? : Bool = true,
) -> MoonDocumentDiffProvider {
  {
    mode,
    ignore_comments,
    status: { requested: mode, effective: mode, fell_back: false },
    did_change: @base_common.Emitter(),
    disposed: false,
  }
}

///|
pub fn MoonDocumentDiffProvider::set_mode(
  self : MoonDocumentDiffProvider,
  mode : MoonDiffMode,
) -> Unit {
  if self.disposed || self.mode == mode {
    return
  }
  self.mode = mode
  self.status = { requested: mode, effective: mode, fell_back: false }
  self.did_change.fire(())
}

///|
pub fn MoonDocumentDiffProvider::get_mode(
  self : MoonDocumentDiffProvider,
) -> MoonDiffMode {
  self.mode
}

///|
pub fn MoonDocumentDiffProvider::set_ignore_comments(
  self : MoonDocumentDiffProvider,
  ignore_comments : Bool,
) -> Unit {
  if self.disposed || self.ignore_comments == ignore_comments {
    return
  }
  self.ignore_comments = ignore_comments
  self.did_change.fire(())
}

///|
pub fn MoonDocumentDiffProvider::get_ignore_comments(
  self : MoonDocumentDiffProvider,
) -> Bool {
  self.ignore_comments
}

///|
pub fn MoonDocumentDiffProvider::get_status(
  self : MoonDocumentDiffProvider,
) -> MoonDiffStatus {
  self.status
}

///|
/// Explicit host-facing coercion keeps the optional package independently
/// checkable while exposing only the common diff contract to DiffEditor.
pub fn MoonDocumentDiffProvider::as_document_diff_provider(
  self : MoonDocumentDiffProvider,
) -> &@diff.DocumentDiffProvider {
  self
}

///|
pub fn MoonDocumentDiffProvider::dispose(
  self : MoonDocumentDiffProvider,
) -> Unit {
  if self.disposed {
    return
  }
  self.disposed = true
  self.did_change.dispose()
}

///|
fn snapshot_lines(snapshot : @model.TextSnapshot) -> Array[String] {
  let lines = []
  for line_number in 1..<=snapshot.line_count() {
    lines.push(snapshot.get_line_content(line_number))
  }
  lines
}

///|
fn same_line_change_shape(
  first : @diff.DocumentDiff,
  second : @diff.DocumentDiff,
) -> Bool {
  if first.changes.length() != second.changes.length() {
    return false
  }
  for index in 0..<first.changes.length() {
    if first.changes[index].original != second.changes[index].original ||
      first.changes[index].modified != second.changes[index].modified {
      return false
    }
  }
  true
}

///|
fn edge_whitespace_signature(line : String) -> (Array[Int], Array[Int]) {
  let leading : Array[Int] = []
  let trailing : Array[Int] = []
  let mut saw_content = false
  for character in line {
    if character.is_whitespace() {
      if saw_content {
        trailing.push(character.to_int())
      } else {
        leading.push(character.to_int())
      }
    } else {
      saw_content = true
      trailing.clear()
    }
  }
  (leading, trailing)
}

///|
fn paired_change_has_edge_whitespace_difference(
  strict : @diff.DocumentDiff,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
) -> Bool {
  for change in strict.changes {
    if change.original.length() != change.modified.length() {
      continue
    }
    for offset in 0..<change.original.length() {
      let original_line = original.get_line_content(
        change.original.start_line_number + offset,
      )
      let modified_line = modified.get_line_content(
        change.modified.start_line_number + offset,
      )
      if edge_whitespace_signature(original_line) !=
        edge_whitespace_signature(modified_line) {
        return true
      }
    }
  }
  false
}

///|
fn valid_hunk_range(start : Int, len : Int, total : Int) -> Bool {
  start >= 0 && len >= 0 && start <= total && len <= total - start
}

///|
fn valid_line(
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
fn changed_ranges(line : @tokdiff.DiffLine) -> Array[@base_common.Range] {
  let ranges = []
  let mut column = 1
  for segment in line.segments {
    let end_column = column + segment.text.length()
    if segment.kind is Changed && end_column > column {
      ranges.push(
        @base_common.Range(line.index + 1, column, line.index + 1, end_column),
      )
    }
    column = end_column
  }
  ranges
}

///|
fn paired_inner_changes(
  original : @tokdiff.DiffLine,
  modified : @tokdiff.DiffLine,
) -> Array[@diff.RangeMapping]? {
  let original_ranges = changed_ranges(original)
  let modified_ranges = changed_ranges(modified)
  if original_ranges.is_empty() || modified_ranges.is_empty() {
    return None
  }
  let mappings = []
  let count = original_ranges.length().min(modified_ranges.length())
  for index in 0..<count {
    mappings.push(
      @diff.RangeMapping(original_ranges[index], modified_ranges[index]),
    )
  }
  Some(mappings)
}

///|
fn paired_change(
  original : @tokdiff.DiffLine,
  modified : @tokdiff.DiffLine,
) -> @diff.DetailedLineRangeMapping {
  @diff.DetailedLineRangeMapping(
    @base_common.LineRange(original.index + 1, original.index + 2),
    @base_common.LineRange(modified.index + 1, modified.index + 2),
    paired_inner_changes(original, modified),
  )
}

///|
fn old_only_change(
  original : @tokdiff.DiffLine,
  modified_cursor : Int,
) -> @diff.DetailedLineRangeMapping {
  @diff.DetailedLineRangeMapping(
    @base_common.LineRange(original.index + 1, original.index + 2),
    @base_common.LineRange(modified_cursor + 1, modified_cursor + 1),
    None,
  )
}

///|
fn new_only_change(
  modified : @tokdiff.DiffLine,
  original_cursor : Int,
) -> @diff.DetailedLineRangeMapping {
  @diff.DetailedLineRangeMapping(
    @base_common.LineRange(original_cursor + 1, original_cursor + 1),
    @base_common.LineRange(modified.index + 1, modified.index + 2),
    None,
  )
}

///|
fn append_rows(
  rows : Array[@tokdiff.DiffRow],
  render_changes : Bool,
  original_lines : Array[String],
  modified_lines : Array[String],
  original_cursor : Int,
  modified_cursor : Int,
  changes : Array[@diff.DetailedLineRangeMapping],
  alignments : Array[@diff.LineRangeMapping],
) -> (Int, Int)? {
  let mut old_cursor = original_cursor
  let mut new_cursor = modified_cursor
  for row in rows {
    match row {
      Paired(original, modified) => {
        if !valid_line(original, old_cursor, original_lines) ||
          !valid_line(modified, new_cursor, modified_lines) {
          return None
        }
        if render_changes {
          changes.push(paired_change(original, modified))
        }
        old_cursor += 1
        new_cursor += 1
      }
      OldOnly(original) => {
        if !valid_line(original, old_cursor, original_lines) {
          return None
        }
        let mapping = old_only_change(original, new_cursor)
        if render_changes {
          changes.push(mapping)
        } else {
          alignments.push(mapping.line_mapping())
        }
        old_cursor += 1
      }
      NewOnly(modified) => {
        if !valid_line(modified, new_cursor, modified_lines) {
          return None
        }
        let mapping = new_only_change(modified, old_cursor)
        if render_changes {
          changes.push(mapping)
        } else {
          alignments.push(mapping.line_mapping())
        }
        new_cursor += 1
      }
    }
  }
  Some((old_cursor, new_cursor))
}

///|
fn adapt_document(
  document : @tokdiff.DiffDocument,
  original_lines : Array[String],
  modified_lines : Array[String],
) -> @diff.DocumentDiff? {
  let changes = []
  let alignments = []
  for hunk in document.hunks {
    if !valid_hunk_range(hunk.old_start, hunk.old_len, original_lines.length()) ||
      !valid_hunk_range(hunk.new_start, hunk.new_len, modified_lines.length()) {
      return None
    }
    let mut old_cursor = hunk.old_start
    let mut new_cursor = hunk.new_start
    for block in hunk.blocks {
      match block {
        ContextBlock(lines) =>
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
        ChangeBlock(rows) =>
          match
            append_rows(
              rows, true, original_lines, modified_lines, old_cursor, new_cursor,
              changes, alignments,
            ) {
            Some((next_old, next_new)) => {
              old_cursor = next_old
              new_cursor = next_new
            }
            None => return None
          }
        IgnoredBlock(rows) =>
          match
            append_rows(
              rows, false, original_lines, modified_lines, old_cursor, new_cursor,
              changes, alignments,
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
  Some({ changes, additional_alignments: alignments })
}

///|
fn specialized_diff(
  mode : MoonDiffMode,
  ignore_comments : Bool,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
) -> (@diff.DocumentDiff, MoonDiffMode, Bool)? {
  let original_lines = snapshot_lines(original)
  let modified_lines = snapshot_lines(modified)
  let (document, effective, fell_back) = match mode {
    Core => return None
    Token =>
      (
        @tokdiff.diff(
          old=original_lines,
          new=modified_lines,
          context=0,
          line_cleanup=true,
          ignore_comments~,
        ),
        Token,
        false,
      )
    Tree => {
      let result = @mbtdiff.diff(
        original.get_value(),
        modified.get_value(),
        options=@mbtdiff.DiffOptions::new(context_lines=0, ignore_comments~),
      )
      (
        result.document(),
        if result.has_fallback() {
          Token
        } else {
          Tree
        },
        result.has_fallback(),
      )
    }
  }
  guard adapt_document(document, original_lines, modified_lines) is Some(diff) else {
    return None
  }
  // Token has no typed failure channel. A differing source cannot silently
  // become an empty comparison unless ignored rows explain the geometry.
  if original_lines != modified_lines &&
    diff.changes.is_empty() &&
    diff.additional_alignments.is_empty() {
    if !ignore_comments {
      return None
    }
    let unfiltered = @tokdiff.diff(
      old=original_lines,
      new=modified_lines,
      context=0,
      line_cleanup=true,
      ignore_comments=false,
    )
    guard adapt_document(unfiltered, original_lines, modified_lines)
      is Some(unfiltered_diff) &&
      !unfiltered_diff.changes.is_empty() else {
      return None
    }
    let ignored_alignments = unfiltered_diff.changes.filter_map(change => {
      if change.original.length() != change.modified.length() {
        Some(change.line_mapping())
      } else {
        None
      }
    })
    let result : @diff.DocumentDiff = {
      changes: [],
      additional_alignments: ignored_alignments,
    }
    return Some((result, effective, fell_back))
  }
  Some((diff, effective, fell_back))
}

///|
pub impl @diff.DocumentDiffProvider for MoonDocumentDiffProvider with fn compute_diff(
  self,
  original,
  modified,
  options,
) {
  let requested = self.mode
  if requested != Core {
    let core = @diff.CoreDocumentDiffProvider()
    let strict = core.compute_diff(original, modified, {
      ignore_trim_whitespace: false,
    })
    let lenient = core.compute_diff(original, modified, {
      ignore_trim_whitespace: true,
    })
    if !same_line_change_shape(strict, lenient) ||
      paired_change_has_edge_whitespace_difference(strict, original, modified) {
      self.status = { requested, effective: Core, fell_back: true }
      return if options.ignore_trim_whitespace { lenient } else { strict }
    }
    match
      specialized_diff(requested, self.ignore_comments, original, modified) {
      Some((result, effective, fell_back)) => {
        self.status = { requested, effective, fell_back }
        return result
      }
      None => ()
    }
  }
  let result = @diff.CoreDocumentDiffProvider().compute_diff(
    original, modified, options,
  )
  self.status = { requested, effective: Core, fell_back: requested != Core }
  result
}

///|
pub impl @diff.DocumentDiffProvider for MoonDocumentDiffProvider with fn on_did_change(
  self,
  listener,
) {
  self.did_change.event(_ => listener())
}

///|
pub extend MoonDiffMode with Eq::{equal, not_equal}

///|
pub extend MoonDiffMode with Debug::{to_repr}

///|
pub extend MoonDiffStatus with Eq::{equal, not_equal}

///|
pub extend MoonDiffStatus with Debug::{to_repr}
