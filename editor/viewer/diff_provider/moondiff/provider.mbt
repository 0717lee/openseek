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
  mut ignore_tests : Bool
  mut status : MoonDiffStatus
  did_change : @base_common.Emitter[Unit]
  mut disposed : Bool
}

///|
pub fn MoonDocumentDiffProvider::MoonDocumentDiffProvider(
  mode? : MoonDiffMode = Core,
  ignore_comments? : Bool = true,
  ignore_tests? : Bool = true,
) -> MoonDocumentDiffProvider {
  {
    mode,
    ignore_comments,
    ignore_tests,
    status: { requested: mode, effective: mode, fell_back: false, },
    did_change: Emitter(),
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
  self.status = { requested: mode, effective: mode, fell_back: false, }
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
  self.status = {
    requested: self.mode,
    effective: self.mode,
    fell_back: false,
  }
  self.did_change.fire(())
}

///|
pub fn MoonDocumentDiffProvider::get_ignore_comments(
  self : MoonDocumentDiffProvider,
) -> Bool {
  self.ignore_comments
}

///|
pub fn MoonDocumentDiffProvider::set_ignore_tests(
  self : MoonDocumentDiffProvider,
  ignore_tests : Bool,
) -> Unit {
  if self.disposed || self.ignore_tests == ignore_tests {
    return
  }
  self.ignore_tests = ignore_tests
  self.status = { requested: self.mode, effective: self.mode, fell_back: false }
  self.did_change.fire(())
}

///|
pub fn MoonDocumentDiffProvider::get_ignore_tests(
  self : MoonDocumentDiffProvider,
) -> Bool {
  self.ignore_tests
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
  line : @mbtdiff.DiffLine,
  expected_index : Int,
  source : Array[String],
) -> Bool {
  line.index == expected_index &&
  expected_index >= 0 &&
  expected_index < source.length() &&
  line.text() == source[expected_index]
}

///|
fn changed_ranges(line : @mbtdiff.DiffLine) -> Array[@base_common.Range] {
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
  original : @mbtdiff.DiffLine,
  modified : @mbtdiff.DiffLine,
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
  original : @mbtdiff.DiffLine,
  modified : @mbtdiff.DiffLine,
) -> @diff.DetailedLineRangeMapping {
  DetailedLineRangeMapping(
    LineRange(original.index + 1, original.index + 2),
    LineRange(modified.index + 1, modified.index + 2),
    paired_inner_changes(original, modified),
  )
}

///|
fn old_only_change(
  original : @mbtdiff.DiffLine,
  modified_cursor : Int,
) -> @diff.DetailedLineRangeMapping {
  DetailedLineRangeMapping(
    LineRange(original.index + 1, original.index + 2),
    LineRange(modified_cursor + 1, modified_cursor + 1),
    None,
  )
}

///|
fn new_only_change(
  modified : @mbtdiff.DiffLine,
  original_cursor : Int,
) -> @diff.DetailedLineRangeMapping {
  DetailedLineRangeMapping(
    LineRange(original_cursor + 1, original_cursor + 1),
    LineRange(modified.index + 1, modified.index + 2),
    None,
  )
}

///|
fn line_ranges_intersect_or_touch(
  left : @base_common.LineRange,
  right : @base_common.LineRange,
) -> Bool {
  left.end_line_number_exclusive >= right.start_line_number &&
  right.end_line_number_exclusive >= left.start_line_number
}

///|
fn line_ranges_intersect(
  left : @base_common.LineRange,
  right : @base_common.LineRange,
) -> Bool {
  !left.is_empty() &&
  !right.is_empty() &&
  left.start_line_number < right.end_line_number_exclusive &&
  right.start_line_number < left.end_line_number_exclusive
}

///|
// MoonDiff exposes changed rows. VS Code's renderer consumes grouped
// DetailedLineRangeMappings, so touching rows must be joined before the
// provider result crosses that boundary.
fn append_coalesced_change(
  changes : Array[@diff.DetailedLineRangeMapping],
  change : @diff.DetailedLineRangeMapping,
) -> Unit {
  if changes.is_empty() {
    changes.push(change)
    return
  }
  let previous = changes[changes.length() - 1]
  if !line_ranges_intersect_or_touch(previous.original, change.original) &&
    !line_ranges_intersect_or_touch(previous.modified, change.modified) {
    changes.push(change)
    return
  }
  let inner_changes = match (previous.inner_changes, change.inner_changes) {
    (Some(previous_inner), Some(change_inner)) => {
      let joined = previous_inner.copy()
      joined.append(change_inner)
      Some(joined)
    }
    _ => None
  }
  changes[changes.length() - 1] = DetailedLineRangeMapping(
    previous.original.join(change.original),
    previous.modified.join(change.modified),
    inner_changes,
  )
}

///|
fn append_coalesced_alignment(
  alignments : Array[@diff.LineRangeMapping],
  alignment : @diff.LineRangeMapping,
) -> Unit {
  if alignments.is_empty() {
    alignments.push(alignment)
    return
  }
  let previous = alignments[alignments.length() - 1]
  if !line_ranges_intersect_or_touch(previous.original, alignment.original) &&
    !line_ranges_intersect_or_touch(previous.modified, alignment.modified) {
    alignments.push(alignment)
    return
  }
  alignments[alignments.length() - 1] = LineRangeMapping(
    previous.original.join(alignment.original),
    previous.modified.join(alignment.modified),
  )
}

///|
fn mapping_overlaps_document(
  mapping : @diff.LineRangeMapping,
  changes : Array[@diff.DetailedLineRangeMapping],
  alignments : Array[@diff.LineRangeMapping],
) -> Bool {
  for change in changes {
    if (
        !mapping.original.is_empty() &&
        line_ranges_intersect(mapping.original, change.original)
      ) ||
      (
        !mapping.modified.is_empty() &&
        line_ranges_intersect(mapping.modified, change.modified)
      ) {
      return true
    }
  }
  for alignment in alignments {
    if (
        !mapping.original.is_empty() &&
        line_ranges_intersect(mapping.original, alignment.original)
      ) ||
      (
        !mapping.modified.is_empty() &&
        line_ranges_intersect(mapping.modified, alignment.modified)
      ) {
      return true
    }
  }
  false
}

///|
// moondiff 0.0.3 can place a filtered one-sided row in a top-level section
// outside the visible hunk that explains the adjacent code change. Recover
// only disjoint one-sided rows as geometry; overlapping rows are already
// represented by a visible change or an IgnoredBlock alignment.
fn append_unrepresented_one_sided_alignments(
  unfiltered : @diff.DocumentDiff,
  changes : Array[@diff.DetailedLineRangeMapping],
  alignments : Array[@diff.LineRangeMapping],
) -> Unit {
  for change in unfiltered.changes {
    let mapping = change.line_mapping()
    if (
        (mapping.original.is_empty() && !mapping.modified.is_empty()) ||
        (mapping.modified.is_empty() && !mapping.original.is_empty())
      ) &&
      !mapping_overlaps_document(mapping, changes, alignments) {
      alignments.push(mapping)
    }
  }
}

///|
fn append_layout_gap(
  old_start : Int,
  old_len : Int,
  new_start : Int,
  new_len : Int,
  changes : Array[@diff.DetailedLineRangeMapping],
  alignments : Array[@diff.LineRangeMapping],
) -> Unit {
  if old_len == new_len {
    return
  }
  let mapping = @diff.LineRangeMapping(
    @base_common.LineRange(old_start + 1, old_start + old_len + 1),
    @base_common.LineRange(new_start + 1, new_start + new_len + 1),
  )
  if !mapping_overlaps_document(mapping, changes, alignments) {
    alignments.push(mapping)
  }
}

///|
// Test filtering removes whole top-level sections before hunk calculation.
// Their line spans remain observable as gaps in DiffLayout, so preserve only
// their height difference as neutral alignment geometry.
fn append_layout_gap_alignments(
  layout : @mbtdiff.DiffLayout,
  original_line_count : Int,
  modified_line_count : Int,
  changes : Array[@diff.DetailedLineRangeMapping],
  alignments : Array[@diff.LineRangeMapping],
) -> Unit {
  guard layout is @mbtdiff.DiffLayout::TopLevelSections(sections) else {
    return
  }
  let mut old_cursor = 0
  let mut new_cursor = 0
  for section in sections {
    let old_start = section.old.map(range => range.start).unwrap_or(old_cursor)
    let new_start = section.new.map(range => range.start).unwrap_or(new_cursor)
    if old_start < old_cursor || new_start < new_cursor {
      return
    }
    append_layout_gap(
      old_cursor,
      old_start - old_cursor,
      new_cursor,
      new_start - new_cursor,
      changes,
      alignments,
    )
    match section.old {
      Some(range) => old_cursor = range.start + range.len
      None => ()
    }
    match section.new {
      Some(range) => new_cursor = range.start + range.len
      None => ()
    }
  }
  if old_cursor <= original_line_count && new_cursor <= modified_line_count {
    append_layout_gap(
      old_cursor,
      original_line_count - old_cursor,
      new_cursor,
      modified_line_count - new_cursor,
      changes,
      alignments,
    )
  }
}

///|
fn append_rows(
  rows : ArrayView[@mbtdiff.DiffRow],
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
  // A ChangeBlock or IgnoredBlock is a coalescing boundary. Keeping its rows
  // local prevents an empty-side anchor from joining mappings across the other
  // block kind and making a geometry-only alignment overlap a real change.
  let block_changes = []
  let block_alignments = []
  for row in rows {
    match row {
      Paired(original, modified) => {
        if !valid_line(original, old_cursor, original_lines) ||
          !valid_line(modified, new_cursor, modified_lines) {
          return None
        }
        if render_changes {
          append_coalesced_change(
            block_changes,
            paired_change(original, modified),
          )
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
          append_coalesced_change(block_changes, mapping)
        } else {
          append_coalesced_alignment(block_alignments, mapping.line_mapping())
        }
        old_cursor += 1
      }
      NewOnly(modified) => {
        if !valid_line(modified, new_cursor, modified_lines) {
          return None
        }
        let mapping = new_only_change(modified, old_cursor)
        if render_changes {
          append_coalesced_change(block_changes, mapping)
        } else {
          append_coalesced_alignment(block_alignments, mapping.line_mapping())
        }
        new_cursor += 1
      }
    }
  }
  changes.append(block_changes)
  alignments.append(block_alignments)
  Some((old_cursor, new_cursor))
}

///|
fn adapt_document(
  document : @mbtdiff.DiffDocument,
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
  Some({ changes, additional_alignments: alignments, })
}

///|
fn unfiltered_lexical_diff(
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
  original_lines : Array[String],
  modified_lines : Array[String],
) -> @diff.DocumentDiff? {
  let document = @mbtdiff.diff(
    original.get_value(),
    modified.get_value(),
    options=@mbtdiff.DiffOptions(
      context_lines=0,
      ignore_comments=false,
      ignore_tests=false,
      mode=@mbtdiff.DiffMode::Lexical,
    ),
  ).document()
  adapt_document(document, original_lines, modified_lines)
}

///|
fn specialized_diff(
  mode : MoonDiffMode,
  ignore_comments : Bool,
  ignore_tests : Bool,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
) -> (@diff.DocumentDiff, MoonDiffMode, Bool)? {
  let original_lines = snapshot_lines(original)
  let modified_lines = snapshot_lines(modified)
  let diff_mode = match mode {
    Core => return None
    Token => @mbtdiff.DiffMode::Lexical
    Tree => @mbtdiff.DiffMode::Ast
  }
  let result = @mbtdiff.diff(
    original.get_value(),
    modified.get_value(),
    options=@mbtdiff.DiffOptions(
      context_lines=0,
      ignore_comments~,
      ignore_tests~,
      mode=diff_mode,
    ),
  )
  let fell_back = mode == Tree && !result.fallbacks().is_empty()
  let effective = if fell_back { Token } else { mode }
  let document = result.document()
  guard adapt_document(document, original_lines, modified_lines) is Some(diff) else {
    return None
  }
  if ignore_tests {
    append_layout_gap_alignments(
      result.layout(),
      original_lines.length(),
      modified_lines.length(),
      diff.changes,
      diff.additional_alignments,
    )
  }
  // A differing source cannot silently become an empty comparison unless the
  // active filter classified every change as ignored.
  if original_lines != modified_lines &&
    diff.changes.is_empty() &&
    diff.additional_alignments.is_empty() {
    if !(ignore_comments || ignore_tests) ||
      !(result.status() is @mbtdiff.DiffStatus::IgnoredOnly) {
      return None
    }
    guard unfiltered_lexical_diff(
        original, modified, original_lines, modified_lines,
      )
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
  if (ignore_comments || ignore_tests) &&
    @diff.normalize_and_validate_document_diff(diff, original, modified) is None {
    if unfiltered_lexical_diff(
        original, modified, original_lines, modified_lines,
      )
      is Some(unfiltered_diff) {
      append_unrepresented_one_sided_alignments(
        unfiltered_diff,
        diff.changes,
        diff.additional_alignments,
      )
    }
  }
  Some((diff, effective, fell_back))
}

///|
fn MoonDocumentDiffProvider::settle_specialized_or_core(
  self : MoonDocumentDiffProvider,
  requested : MoonDiffMode,
  specialized : (@diff.DocumentDiff, MoonDiffMode, Bool)?,
  core_fallback : @diff.DocumentDiff,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
) -> @diff.DocumentDiff {
  match specialized {
    Some((candidate, effective, fell_back)) =>
      match
        @diff.normalize_and_validate_document_diff(
          candidate, original, modified,
        ) {
        Some(result) => {
          self.status = { requested, effective, fell_back, }
          return result
        }
        None => ()
      }
    None => ()
  }
  self.status = { requested, effective: Core, fell_back: requested != Core, }
  core_fallback
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
      self.status = { requested, effective: Core, fell_back: true, }
      return if options.ignore_trim_whitespace { lenient } else { strict }
    }
    return self.settle_specialized_or_core(
      requested,
      specialized_diff(
        requested,
        self.ignore_comments,
        self.ignore_tests,
        original,
        modified,
      ),
      if options.ignore_trim_whitespace {
        lenient
      } else {
        strict
      },
      original,
      modified,
    )
  }
  let core = @diff.CoreDocumentDiffProvider().compute_diff(
    original, modified, options,
  )
  self.settle_specialized_or_core(requested, None, core, original, modified)
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
