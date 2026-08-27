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
fn change_has_edge_whitespace_difference(
  change : @diff.DetailedLineRangeMapping,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
) -> Bool {
  if change.original.length() != change.modified.length() {
    return false
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
  false
}

///|
fn paired_change_has_edge_whitespace_difference(
  strict : @diff.DocumentDiff,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
) -> Bool {
  strict.changes.any(change => {
    change_has_edge_whitespace_difference(change, original, modified)
  })
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
// Recover filtered one-sided rows that are not already represented by a
// visible change or an IgnoredBlock alignment.
fn append_unrepresented_one_sided_alignments(
  unfiltered : @diff.DocumentDiff,
  changes : Array[@diff.DetailedLineRangeMapping],
  alignments : Array[@diff.LineRangeMapping],
) -> Unit {
  for change in unfiltered.changes {
    let mapping = change.line_mapping()
    if mapping.original.is_empty() && !mapping.modified.is_empty() {
      let mut run_start : Int? = None
      for
        line in mapping.modified.start_line_number..<mapping.modified.end_line_number_exclusive {
        let unit = @diff.LineRangeMapping(
          mapping.original,
          @base_common.LineRange(line, line + 1),
        )
        if mapping_overlaps_document(unit, changes, alignments) {
          if run_start is Some(start) {
            alignments.push(
              @diff.LineRangeMapping(
                mapping.original,
                @base_common.LineRange(start, line),
              ),
            )
            run_start = None
          }
        } else if run_start is None {
          run_start = Some(line)
        }
      }
      if run_start is Some(start) {
        alignments.push(
          @diff.LineRangeMapping(
            mapping.original,
            @base_common.LineRange(
              start,
              mapping.modified.end_line_number_exclusive,
            ),
          ),
        )
      }
    } else if mapping.modified.is_empty() && !mapping.original.is_empty() {
      let mut run_start : Int? = None
      for
        line in mapping.original.start_line_number..<mapping.original.end_line_number_exclusive {
        let unit = @diff.LineRangeMapping(
          @base_common.LineRange(line, line + 1),
          mapping.modified,
        )
        if mapping_overlaps_document(unit, changes, alignments) {
          if run_start is Some(start) {
            alignments.push(
              @diff.LineRangeMapping(
                @base_common.LineRange(start, line),
                mapping.modified,
              ),
            )
            run_start = None
          }
        } else if run_start is None {
          run_start = Some(line)
        }
      }
      if run_start is Some(start) {
        alignments.push(
          @diff.LineRangeMapping(
            @base_common.LineRange(
              start,
              mapping.original.end_line_number_exclusive,
            ),
            mapping.modified,
          ),
        )
      }
    }
  }
}

///|
fn compare_line_mapping_start(
  left : @diff.LineRangeMapping,
  right : @diff.LineRangeMapping,
) -> Int {
  let original = left.original.start_line_number -
    right.original.start_line_number
  if original != 0 {
    return original
  }
  left.modified.start_line_number - right.modified.start_line_number
}

///|
fn compare_detailed_mapping_start(
  left : @diff.DetailedLineRangeMapping,
  right : @diff.DetailedLineRangeMapping,
) -> Int {
  compare_line_mapping_start(left.line_mapping(), right.line_mapping())
}

///|
fn append_flattened_change(
  changes : Array[@diff.DetailedLineRangeMapping],
  change : @diff.DetailedLineRangeMapping,
) -> Unit {
  if changes.is_empty() {
    changes.push(change)
    return
  }
  let previous = changes[changes.length() - 1]
  if !line_ranges_intersect_or_touch(previous.original, change.original) ||
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
fn append_flattened_alignment(
  alignments : Array[@diff.LineRangeMapping],
  alignment : @diff.LineRangeMapping,
) -> Unit {
  if alignments.is_empty() {
    alignments.push(alignment)
    return
  }
  let previous = alignments[alignments.length() - 1]
  if !line_ranges_intersect_or_touch(previous.original, alignment.original) ||
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
fn order_document_mappings(diff : @diff.DocumentDiff) -> @diff.DocumentDiff {
  let raw_changes = diff.changes.copy()
  raw_changes.sort_by(compare_detailed_mapping_start)
  let changes : Array[@diff.DetailedLineRangeMapping] = []
  for change in raw_changes {
    append_flattened_change(changes, change)
  }
  let raw_alignments = diff.additional_alignments.copy()
  raw_alignments.sort_by(compare_line_mapping_start)
  let alignments : Array[@diff.LineRangeMapping] = []
  for alignment in raw_alignments {
    append_flattened_alignment(alignments, alignment)
  }
  { changes, additional_alignments: alignments }
}

///|
priv struct FlattenedSection {
  fragment : @mbtdiff.DiffFragment
  old_base : Int
  new_base : Int
  old_len : Int
  new_len : Int
  matched : Bool
  layout : @diff.LineRangeMapping
}

///|
priv struct IgnoredTestOwnership {
  original : Array[@base_common.LineRange]
  modified : Array[@base_common.LineRange]
}

///|
fn semantic_line_count(lines : Array[String]) -> Int {
  if !lines.is_empty() && lines[lines.length() - 1].is_empty() {
    lines.length() - 1
  } else {
    lines.length()
  }
}

///|
fn source_line_slice(lines : Array[String], start : Int, len : Int) -> String {
  if len == 0 {
    return ""
  }
  let selected : Array[String] = []
  for index in start..<(start + len) {
    selected.push(lines[index])
  }
  selected.join("\n") + "\n"
}

///|
fn raw_range_difference_is_ignored(
  original_lines : Array[String],
  old_start : Int,
  old_len : Int,
  modified_lines : Array[String],
  new_start : Int,
  new_len : Int,
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
) -> Bool {
  let old_source = source_line_slice(original_lines, old_start, old_len)
  let new_source = source_line_slice(modified_lines, new_start, new_len)
  if old_source == new_source {
    return true
  }
  if !ignore_comments && !ignore_tests {
    return false
  }
  @mbtdiff.diff(
    old_source,
    new_source,
    options=@mbtdiff.DiffOptions(
      context_lines=0,
      ignore_comments~,
      ignore_tests~,
      mode~,
    ),
  ).status()
  is @mbtdiff.DiffStatus::IgnoredOnly
}

///|
fn source_ignored_test_ranges(
  source : @model.TextSnapshot,
  lines : Array[String],
  mode : @mbtdiff.DiffMode,
) -> Array[@base_common.LineRange]? {
  if source.get_value().is_empty() {
    return Some([])
  }
  let probe = @model.TextSnapshot(source.get_value() + "\n")
  let probe_lines = snapshot_lines(probe)
  let document = @mbtdiff.diff(
    source.get_value(),
    probe.get_value(),
    options=@mbtdiff.DiffOptions(
      context_lines=0,
      ignore_comments=false,
      ignore_tests=false,
      mode~,
    ),
  ).document()
  guard document is TopLevel(top) &&
    valid_top_level_orders(
      top,
      semantic_line_count(lines),
      semantic_line_count(probe_lines),
    ) else {
    return None
  }
  let ranges : Array[@base_common.LineRange] = []
  for section in top.sections {
    guard section is Matched(old~, new~, ..) && old == new else { return None }
    let empty : Array[String] = []
    if raw_range_difference_is_ignored(
        lines,
        old.start,
        old.len,
        empty,
        0,
        0,
        false,
        true,
        mode,
      ) {
      ranges.push(
        @base_common.LineRange(old.start + 1, old.start + old.len + 1),
      )
    }
  }
  Some(ranges)
}

///|
fn ignored_test_ownership(
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
  original_lines : Array[String],
  modified_lines : Array[String],
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
) -> IgnoredTestOwnership? {
  if !ignore_tests {
    return Some({ original: [], modified: [] })
  }
  match
    (
      source_ignored_test_ranges(original, original_lines, mode),
      source_ignored_test_ranges(modified, modified_lines, mode),
    ) {
    (Some(original_ranges), Some(modified_ranges)) =>
      Some({ original: original_ranges, modified: modified_ranges })
    _ => Some({ original: [], modified: [] })
  }
}

///|
fn strip_owned_lines(
  lines : Array[String],
  start : Int,
  len : Int,
  owned : Array[@base_common.LineRange],
) -> (Array[String], Bool) {
  let visible : Array[String] = []
  let mut removed = false
  for index in start..<(start + len) {
    if owned.any(range => range.contains(index + 1)) {
      removed = true
    } else {
      visible.push(lines[index])
    }
  }
  (visible, removed)
}

///|
fn range_difference_is_ignored(
  original_lines : Array[String],
  old_start : Int,
  old_len : Int,
  modified_lines : Array[String],
  new_start : Int,
  new_len : Int,
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
) -> Bool {
  let old_source = source_line_slice(original_lines, old_start, old_len)
  let new_source = source_line_slice(modified_lines, new_start, new_len)
  if old_source == new_source {
    return true
  }
  if !ignore_tests {
    return raw_range_difference_is_ignored(
      original_lines, old_start, old_len, modified_lines, new_start, new_len, ignore_comments,
      false, mode,
    )
  }
  let (old_visible, old_removed) = strip_owned_lines(
    original_lines,
    old_start,
    old_len,
    test_ownership.original,
  )
  let (new_visible, new_removed) = strip_owned_lines(
    modified_lines,
    new_start,
    new_len,
    test_ownership.modified,
  )
  if !old_removed && !new_removed {
    return if ignore_comments {
      raw_range_difference_is_ignored(
        original_lines, old_start, old_len, modified_lines, new_start, new_len, true,
        false, mode,
      )
    } else {
      false
    }
  }
  let old_visible_source = source_line_slice(
    old_visible,
    0,
    old_visible.length(),
  )
  let new_visible_source = source_line_slice(
    new_visible,
    0,
    new_visible.length(),
  )
  if old_visible_source == new_visible_source {
    return true
  }
  ignore_comments &&
  @mbtdiff.diff(
    old_visible_source,
    new_visible_source,
    options=@mbtdiff.DiffOptions(
      context_lines=0,
      ignore_comments=true,
      ignore_tests=false,
      mode~,
    ),
  ).status()
  is @mbtdiff.DiffStatus::IgnoredOnly
}

///|
fn rebase_line_mapping(
  mapping : @diff.LineRangeMapping,
  old_base : Int,
  new_base : Int,
) -> @diff.LineRangeMapping {
  @diff.LineRangeMapping(
    @base_common.LineRange(
      mapping.original.start_line_number + old_base,
      mapping.original.end_line_number_exclusive + old_base,
    ),
    @base_common.LineRange(
      mapping.modified.start_line_number + new_base,
      mapping.modified.end_line_number_exclusive + new_base,
    ),
  )
}

///|
fn ignored_range_geometry(
  original_lines : Array[String],
  old_start : Int,
  old_len : Int,
  modified_lines : Array[String],
  new_start : Int,
  new_len : Int,
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
) -> Array[@diff.LineRangeMapping]? {
  if !range_difference_is_ignored(
      original_lines, old_start, old_len, modified_lines, new_start, new_len, ignore_comments,
      ignore_tests, mode, test_ownership,
    ) {
    return None
  }
  let core = @diff.CoreDocumentDiffProvider().compute_diff(
    @model.TextSnapshot(source_line_slice(original_lines, old_start, old_len)),
    @model.TextSnapshot(source_line_slice(modified_lines, new_start, new_len)),
    { ignore_trim_whitespace: false },
  )
  let alignments = core.changes.filter_map(change => {
    if change.original.length() != change.modified.length() {
      Some(rebase_line_mapping(change.line_mapping(), old_start, new_start))
    } else {
      None
    }
  })
  if old_len != new_len && alignments.is_empty() {
    None
  } else {
    Some(alignments)
  }
}

///|
fn valid_top_level_orders(
  top : @mbtdiff.TopLevelDiff,
  original_line_count : Int,
  modified_line_count : Int,
) -> Bool {
  let old_seen = Array::make(top.sections.length(), false)
  let new_seen = Array::make(top.sections.length(), false)
  let mut new_end = 0
  for index in top.new_order {
    if index < 0 || index >= top.sections.length() || new_seen[index] {
      return false
    }
    let range = match top.sections[index] {
      Matched(new~, ..) | Inserted(new~, ..) => new
      Deleted(..) => return false
    }
    if !valid_hunk_range(range.start, range.len, modified_line_count) ||
      range.start < new_end {
      return false
    }
    new_seen[index] = true
    new_end = range.start + range.len
  }
  let mut old_end = 0
  for index in top.old_order {
    if index < 0 || index >= top.sections.length() || old_seen[index] {
      return false
    }
    let range = match top.sections[index] {
      Matched(old~, ..) | Deleted(old~, ..) => old
      Inserted(..) => return false
    }
    if !valid_hunk_range(range.start, range.len, original_line_count) ||
      range.start < old_end {
      return false
    }
    old_seen[index] = true
    old_end = range.start + range.len
  }
  for index, section in top.sections {
    match section {
      Matched(..) => if !old_seen[index] || !new_seen[index] { return false }
      Deleted(..) => if !old_seen[index] || new_seen[index] { return false }
      Inserted(..) => if old_seen[index] || !new_seen[index] { return false }
    }
  }
  true
}

///|
fn flatten_top_level_sections(
  top : @mbtdiff.TopLevelDiff,
  original_lines : Array[String],
  modified_lines : Array[String],
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
) -> Array[FlattenedSection]? {
  let original_line_count = semantic_line_count(original_lines)
  let modified_line_count = semantic_line_count(modified_lines)
  if top.reordered ||
    !valid_top_level_orders(top, original_line_count, modified_line_count) {
    return None
  }
  let sections : Array[FlattenedSection] = []
  let mut old_order_index = 0
  let mut new_order_index = 0
  let mut old_cursor = 0
  let mut new_cursor = 0
  while old_order_index < top.old_order.length() ||
        new_order_index < top.new_order.length() {
    let has_old = old_order_index < top.old_order.length()
    let has_new = new_order_index < top.new_order.length()
    let old_index = if has_old { top.old_order[old_order_index] } else { -1 }
    let new_index = if has_new { top.new_order[new_order_index] } else { -1 }
    let old_target = if has_old {
      match top.sections[old_index] {
        Matched(old~, ..) | Deleted(old~, ..) => old.start
        Inserted(..) => return None
      }
    } else {
      original_line_count
    }
    let new_target = if has_new {
      match top.sections[new_index] {
        Matched(new~, ..) | Inserted(new~, ..) => new.start
        Deleted(..) => return None
      }
    } else {
      modified_line_count
    }
    if old_target < old_cursor || new_target < new_cursor {
      return None
    }
    let old_gap_len = old_target - old_cursor
    let new_gap_len = new_target - new_cursor
    if source_line_slice(original_lines, old_cursor, old_gap_len) ==
      source_line_slice(modified_lines, new_cursor, new_gap_len) {
      old_cursor = old_target
      new_cursor = new_target
    }
    if has_old && has_new && old_index == new_index {
      guard top.sections[old_index] is Matched(old~, new~, diff~) else {
        return None
      }
      if old_cursor != old_target || new_cursor != new_target {
        if !range_difference_is_ignored(
            original_lines,
            old_cursor,
            old_target - old_cursor,
            modified_lines,
            new_cursor,
            new_target - new_cursor,
            ignore_comments,
            ignore_tests,
            mode,
            test_ownership,
          ) {
          return None
        }
        old_cursor = old_target
        new_cursor = new_target
      }
      sections.push({
        fragment: diff,
        old_base: old.start,
        new_base: new.start,
        old_len: old.len,
        new_len: new.len,
        matched: true,
        layout: @diff.LineRangeMapping(
          @base_common.LineRange(old.start + 1, old.start + old.len + 1),
          @base_common.LineRange(new.start + 1, new.start + new.len + 1),
        ),
      })
      old_cursor = old.start + old.len
      new_cursor = new.start + new.len
      old_order_index += 1
      new_order_index += 1
      continue
    }
    if has_old &&
      has_new &&
      old_cursor == old_target &&
      new_cursor == new_target &&
      top.sections[old_index] is Deleted(old~, diff=old_diff) &&
      top.sections[new_index] is Inserted(new~, diff=new_diff) {
      sections.push({
        fragment: old_diff,
        old_base: old.start,
        new_base: new_cursor,
        old_len: old.len,
        new_len: 0,
        matched: false,
        layout: @diff.LineRangeMapping(
          @base_common.LineRange(old.start + 1, old.start + old.len + 1),
          @base_common.LineRange(new_cursor + 1, new_cursor + 1),
        ),
      })
      old_cursor = old.start + old.len
      old_order_index += 1
      sections.push({
        fragment: new_diff,
        old_base: old_cursor,
        new_base: new.start,
        old_len: 0,
        new_len: new.len,
        matched: false,
        layout: @diff.LineRangeMapping(
          @base_common.LineRange(old_cursor + 1, old_cursor + 1),
          @base_common.LineRange(new.start + 1, new.start + new.len + 1),
        ),
      })
      new_cursor = new.start + new.len
      new_order_index += 1
      continue
    }
    if has_old &&
      old_cursor == old_target &&
      top.sections[old_index] is Deleted(old~, diff~) {
      sections.push({
        fragment: diff,
        old_base: old.start,
        new_base: new_cursor,
        old_len: old.len,
        new_len: 0,
        matched: false,
        layout: @diff.LineRangeMapping(
          @base_common.LineRange(old.start + 1, old.start + old.len + 1),
          @base_common.LineRange(new_cursor + 1, new_cursor + 1),
        ),
      })
      old_cursor = old.start + old.len
      old_order_index += 1
      continue
    }
    if has_new &&
      new_cursor == new_target &&
      top.sections[new_index] is Inserted(new~, diff~) {
      sections.push({
        fragment: diff,
        old_base: old_cursor,
        new_base: new.start,
        old_len: 0,
        new_len: new.len,
        matched: false,
        layout: @diff.LineRangeMapping(
          @base_common.LineRange(old_cursor + 1, old_cursor + 1),
          @base_common.LineRange(new.start + 1, new.start + new.len + 1),
        ),
      })
      new_cursor = new.start + new.len
      new_order_index += 1
      continue
    }
    if (old_cursor < old_target || new_cursor < new_target) &&
      range_difference_is_ignored(
        original_lines,
        old_cursor,
        old_target - old_cursor,
        modified_lines,
        new_cursor,
        new_target - new_cursor,
        ignore_comments,
        ignore_tests,
        mode,
        test_ownership,
      ) {
      old_cursor = old_target
      new_cursor = new_target
      continue
    }
    return None
  }
  Some(sections)
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
// Test filtering removes whole top-level sections before fragment calculation.
// Their line spans remain observable between semantic section ranges, so
// preserve only their height difference as neutral alignment geometry.
fn append_layout_gap_alignments(
  layout : ArrayView[@diff.LineRangeMapping],
  original_lines : Array[String],
  modified_lines : Array[String],
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
  changes : Array[@diff.DetailedLineRangeMapping],
  alignments : Array[@diff.LineRangeMapping],
) -> Bool {
  let mut old_cursor = 0
  let mut new_cursor = 0
  for section in layout {
    let old_start = section.original.start_line_number - 1
    let new_start = section.modified.start_line_number - 1
    if old_start < old_cursor || new_start < new_cursor {
      return false
    }
    let old_len = old_start - old_cursor
    let new_len = new_start - new_cursor
    if !range_difference_is_ignored(
        original_lines, old_cursor, old_len, modified_lines, new_cursor, new_len,
        ignore_comments, ignore_tests, mode, test_ownership,
      ) {
      return false
    }
    append_layout_gap(
      old_cursor, old_len, new_cursor, new_len, changes, alignments,
    )
    old_cursor = section.original.end_line_number_exclusive - 1
    new_cursor = section.modified.end_line_number_exclusive - 1
  }
  if old_cursor > original_lines.length() ||
    new_cursor > modified_lines.length() {
    return false
  }
  let old_len = original_lines.length() - old_cursor
  let new_len = modified_lines.length() - new_cursor
  if !range_difference_is_ignored(
      original_lines, old_cursor, old_len, modified_lines, new_cursor, new_len, ignore_comments,
      ignore_tests, mode, test_ownership,
    ) {
    return false
  }
  append_layout_gap(
    old_cursor, old_len, new_cursor, new_len, changes, alignments,
  )
  true
}

///|
fn line_is_test_owned(
  line_number : Int,
  ranges : Array[@base_common.LineRange],
) -> Bool {
  ranges.any(range => range.contains(line_number))
}

///|
fn ignored_rows_are_filter_owned(
  rows : ArrayView[@mbtdiff.DiffRow],
  original_lines : Array[String],
  modified_lines : Array[String],
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
) -> Bool {
  for row in rows {
    match row {
      Paired(original, modified) => {
        if original.text() == modified.text() {
          continue
        }
        if ignore_tests &&
          line_is_test_owned(original.index + 1, test_ownership.original) &&
          line_is_test_owned(modified.index + 1, test_ownership.modified) {
          continue
        }
        if !ignore_comments ||
          !raw_range_difference_is_ignored(
            original_lines,
            original.index,
            1,
            modified_lines,
            modified.index,
            1,
            true,
            false,
            mode,
          ) {
          return false
        }
      }
      OldOnly(original) => {
        if ignore_tests &&
          line_is_test_owned(original.index + 1, test_ownership.original) {
          continue
        }
        let empty : Array[String] = []
        if !ignore_comments ||
          !raw_range_difference_is_ignored(
            original_lines,
            original.index,
            1,
            empty,
            0,
            0,
            true,
            false,
            mode,
          ) {
          return false
        }
      }
      NewOnly(modified) => {
        if ignore_tests &&
          line_is_test_owned(modified.index + 1, test_ownership.modified) {
          continue
        }
        let empty : Array[String] = []
        if !ignore_comments ||
          !raw_range_difference_is_ignored(
            empty,
            0,
            0,
            modified_lines,
            modified.index,
            1,
            true,
            false,
            mode,
          ) {
          return false
        }
      }
    }
  }
  true
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
fn adapt_hunk_document(
  document : @mbtdiff.HunkDocument,
  old_base : Int,
  new_base : Int,
  old_len : Int,
  new_len : Int,
  original_lines : Array[String],
  modified_lines : Array[String],
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
) -> @diff.DocumentDiff? {
  for hunk in document.hunks {
    if !valid_hunk_range(hunk.old_start, hunk.old_len, old_len) ||
      !valid_hunk_range(hunk.new_start, hunk.new_len, new_len) {
      return None
    }
  }
  let rebased = document.rebase(old_base, new_base)
  let changes = []
  let alignments = []
  for hunk in rebased.hunks {
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
        IgnoredBlock(rows) => {
          if !ignored_rows_are_filter_owned(
              rows, original_lines, modified_lines, ignore_comments, ignore_tests,
              mode, test_ownership,
            ) {
            return None
          }
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
    }
    if old_cursor != hunk.old_start + hunk.old_len ||
      new_cursor != hunk.new_start + hunk.new_len {
      return None
    }
  }
  Some({ changes, additional_alignments: alignments, })
}

///|
fn adapt_document(
  document : @mbtdiff.DiffDocument,
  original_lines : Array[String],
  modified_lines : Array[String],
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
) -> (@diff.DocumentDiff, Array[@diff.LineRangeMapping])? {
  match document {
    Whole(fragment) => {
      guard adapt_hunk_document(
          fragment.document,
          0,
          0,
          original_lines.length(),
          modified_lines.length(),
          original_lines,
          modified_lines,
          ignore_comments,
          ignore_tests,
          mode,
          test_ownership,
        )
        is Some(diff) else {
        return None
      }
      Some((order_document_mappings(diff), []))
    }
    TopLevel(top) => {
      guard flatten_top_level_sections(
          top, original_lines, modified_lines, ignore_comments, ignore_tests, mode,
          test_ownership,
        )
        is Some(sections) else {
        return None
      }
      let changes : Array[@diff.DetailedLineRangeMapping] = []
      let alignments : Array[@diff.LineRangeMapping] = []
      let layout : Array[@diff.LineRangeMapping] = []
      for section in sections {
        guard adapt_hunk_document(
            section.fragment.document,
            section.old_base,
            section.new_base,
            section.old_len,
            section.new_len,
            original_lines,
            modified_lines,
            ignore_comments,
            ignore_tests,
            mode,
            test_ownership,
          )
          is Some(fragment_diff) else {
          return None
        }
        changes.append(fragment_diff.changes)
        alignments.append(fragment_diff.additional_alignments)
        if section.matched &&
          section.old_len != section.new_len &&
          fragment_diff.changes.is_empty() &&
          fragment_diff.additional_alignments.is_empty() {
          guard ignored_range_geometry(
              original_lines,
              section.old_base,
              section.old_len,
              modified_lines,
              section.new_base,
              section.new_len,
              ignore_comments,
              ignore_tests,
              mode,
              test_ownership,
            )
            is Some(section_alignments) else {
            return None
          }
          alignments.append(section_alignments)
        }
        layout.push(section.layout)
      }
      let diff = order_document_mappings({
        changes,
        additional_alignments: alignments,
      })
      Some((diff, layout))
    }
  }
}

///|
fn fragment_has_fallback(fragment : @mbtdiff.DiffFragment) -> Bool {
  !fragment.fallbacks.is_empty()
}

///|
fn document_has_fallback(document : @mbtdiff.DiffDocument) -> Bool {
  match document {
    Whole(fragment) => fragment_has_fallback(fragment)
    TopLevel(top) =>
      top.sections.any(section => {
        match section {
          Matched(diff~, ..) | Deleted(diff~, ..) | Inserted(diff~, ..) =>
            fragment_has_fallback(diff)
        }
      })
  }
}

///|
fn source_range_is_ignored(
  lines : Array[String],
  start : Int,
  len : Int,
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
) -> Bool {
  let empty : Array[String] = []
  raw_range_difference_is_ignored(
    lines, start, len, empty, 0, 0, ignore_comments, ignore_tests, mode,
  )
}

///|
fn ignored_only_semantic_geometry(
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
  original_lines : Array[String],
  modified_lines : Array[String],
  ignore_comments : Bool,
  ignore_tests : Bool,
  mode : @mbtdiff.DiffMode,
  test_ownership : IgnoredTestOwnership,
) -> @diff.DocumentDiff? {
  let document = @mbtdiff.diff(
    original.get_value(),
    modified.get_value(),
    options=@mbtdiff.DiffOptions(
      context_lines=0,
      ignore_comments=false,
      ignore_tests=false,
      mode~,
    ),
  ).document()
  guard document is TopLevel(top) &&
    valid_top_level_orders(
      top,
      semantic_line_count(original_lines),
      semantic_line_count(modified_lines),
    ) else {
    return None
  }
  let retained = Array::make(top.sections.length(), false)
  for index, section in top.sections {
    match section {
      Matched(old~, new~, ..) => {
        let old_ignored = source_range_is_ignored(
          original_lines,
          old.start,
          old.len,
          ignore_comments,
          ignore_tests,
          mode,
        )
        let new_ignored = source_range_is_ignored(
          modified_lines,
          new.start,
          new.len,
          ignore_comments,
          ignore_tests,
          mode,
        )
        if old_ignored != new_ignored {
          return None
        }
        retained[index] = !old_ignored
      }
      Deleted(old~, ..) =>
        if !source_range_is_ignored(
            original_lines,
            old.start,
            old.len,
            ignore_comments,
            ignore_tests,
            mode,
          ) {
          return None
        }
      Inserted(new~, ..) =>
        if !source_range_is_ignored(
            modified_lines,
            new.start,
            new.len,
            ignore_comments,
            ignore_tests,
            mode,
          ) {
          return None
        }
    }
  }
  let old_retained = top.old_order.filter(index => retained[index])
  let new_retained = top.new_order.filter(index => retained[index])
  if old_retained != new_retained {
    return None
  }
  let layout : Array[@diff.LineRangeMapping] = []
  let alignments : Array[@diff.LineRangeMapping] = []
  for index in old_retained {
    guard top.sections[index] is Matched(old~, new~, ..) else { return None }
    let mapping = @diff.LineRangeMapping(
      @base_common.LineRange(old.start + 1, old.start + old.len + 1),
      @base_common.LineRange(new.start + 1, new.start + new.len + 1),
    )
    layout.push(mapping)
    if old.len != new.len {
      guard ignored_range_geometry(
          original_lines,
          old.start,
          old.len,
          modified_lines,
          new.start,
          new.len,
          ignore_comments,
          ignore_tests,
          mode,
          test_ownership,
        )
        is Some(section_alignments) else {
        return None
      }
      alignments.append(section_alignments)
    }
  }
  let changes : Array[@diff.DetailedLineRangeMapping] = []
  if !append_layout_gap_alignments(
      layout, original_lines, modified_lines, ignore_comments, ignore_tests, mode,
      test_ownership, changes, alignments,
    ) {
    return None
  }
  Some(order_document_mappings({ changes, additional_alignments: alignments }))
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
  match
    adapt_document(
      document,
      original_lines,
      modified_lines,
      false,
      false,
      @mbtdiff.DiffMode::Lexical,
      { original: [], modified: [] },
    ) {
    Some((diff, _)) => Some(diff)
    None => None
  }
}

///|
fn mapping_has_whitespace_conflict(
  change : @diff.DetailedLineRangeMapping,
  original_lines : Array[String],
  modified_lines : Array[String],
) -> Bool {
  let original = @model.TextSnapshot(
    source_line_slice(
      original_lines,
      change.original.start_line_number - 1,
      change.original.length(),
    ),
  )
  let modified = @model.TextSnapshot(
    source_line_slice(
      modified_lines,
      change.modified.start_line_number - 1,
      change.modified.length(),
    ),
  )
  let core = @diff.CoreDocumentDiffProvider()
  let strict = core.compute_diff(original, modified, {
    ignore_trim_whitespace: false,
  })
  let lenient = core.compute_diff(original, modified, {
    ignore_trim_whitespace: true,
  })
  !same_line_change_shape(strict, lenient) ||
  paired_change_has_edge_whitespace_difference(strict, original, modified)
}

///|
fn specialized_source_coverage(
  mode : MoonDiffMode,
  ignore_comments : Bool,
  ignore_tests : Bool,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
  specialized : @diff.DocumentDiff,
  test_ownership : IgnoredTestOwnership,
) -> (Bool, Bool) {
  if !ignore_comments && !ignore_tests {
    return (true, false)
  }
  let diff_mode = match mode {
    Core => return (false, false)
    Token => @mbtdiff.DiffMode::Lexical
    Tree => @mbtdiff.DiffMode::Ast
  }
  let original_lines = snapshot_lines(original)
  let modified_lines = snapshot_lines(modified)
  let mut old_cursor = 0
  let mut new_cursor = 0
  let mut saw_ignored_difference = false
  for visible in specialized.changes {
    let old_start = visible.original.start_line_number - 1
    let new_start = visible.modified.start_line_number - 1
    if old_start < old_cursor || new_start < new_cursor {
      return (false, saw_ignored_difference)
    }
    let old_len = old_start - old_cursor
    let new_len = new_start - new_cursor
    if source_line_slice(original_lines, old_cursor, old_len) !=
      source_line_slice(modified_lines, new_cursor, new_len) {
      if !range_difference_is_ignored(
          original_lines, old_cursor, old_len, modified_lines, new_cursor, new_len,
          ignore_comments, ignore_tests, diff_mode, test_ownership,
        ) {
        return (false, saw_ignored_difference)
      }
      saw_ignored_difference = true
    }
    if mapping_has_whitespace_conflict(visible, original_lines, modified_lines) {
      return (false, saw_ignored_difference)
    }
    old_cursor = visible.original.end_line_number_exclusive - 1
    new_cursor = visible.modified.end_line_number_exclusive - 1
  }
  if old_cursor > original_lines.length() ||
    new_cursor > modified_lines.length() {
    return (false, saw_ignored_difference)
  }
  let old_len = original_lines.length() - old_cursor
  let new_len = modified_lines.length() - new_cursor
  if source_line_slice(original_lines, old_cursor, old_len) !=
    source_line_slice(modified_lines, new_cursor, new_len) {
    if !range_difference_is_ignored(
        original_lines, old_cursor, old_len, modified_lines, new_cursor, new_len,
        ignore_comments, ignore_tests, diff_mode, test_ownership,
      ) {
      return (false, saw_ignored_difference)
    }
    saw_ignored_difference = true
  }
  (true, saw_ignored_difference)
}

///|
fn specialized_diff(
  mode : MoonDiffMode,
  ignore_comments : Bool,
  ignore_tests : Bool,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
  strict : @diff.DocumentDiff,
  test_ownership : IgnoredTestOwnership,
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
  let document = result.document()
  let fell_back = mode == Tree && document_has_fallback(document)
  let effective = if fell_back { Token } else { mode }
  guard adapt_document(
      document, original_lines, modified_lines, ignore_comments, ignore_tests, diff_mode,
      test_ownership,
    )
    is Some((diff, layout)) else {
    return None
  }
  if (ignore_comments || ignore_tests) &&
    document is TopLevel(_) &&
    !append_layout_gap_alignments(
      layout,
      original_lines,
      modified_lines,
      ignore_comments,
      ignore_tests,
      diff_mode,
      test_ownership,
      diff.changes,
      diff.additional_alignments,
    ) {
    return None
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
    if ignored_only_semantic_geometry(
        original, modified, original_lines, modified_lines, ignore_comments, ignore_tests,
        diff_mode, test_ownership,
      )
      is Some(semantic_geometry) {
      return Some((semantic_geometry, effective, fell_back))
    }
    let geometry_changes = match
      unfiltered_lexical_diff(
        original, modified, original_lines, modified_lines,
      ) {
      Some(unfiltered_diff) if !unfiltered_diff.changes.is_empty() =>
        unfiltered_diff.changes
      _ => strict.changes
    }
    let ignored_alignments = geometry_changes.filter_map(change => {
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
    if original_lines.length() != modified_lines.length() &&
      ignored_alignments.is_empty() {
      return None
    }
    return Some((order_document_mappings(result), effective, fell_back))
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
  Some((order_document_mappings(diff), effective, fell_back))
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
    let whitespace_conflict = !same_line_change_shape(strict, lenient) ||
      paired_change_has_edge_whitespace_difference(strict, original, modified)
    let diff_mode = match requested {
      Token => @mbtdiff.DiffMode::Lexical
      Tree => @mbtdiff.DiffMode::Ast
      Core => @mbtdiff.DiffMode::Lexical
    }
    let original_lines = snapshot_lines(original)
    let modified_lines = snapshot_lines(modified)
    let test_ownership = ignored_test_ownership(
      original,
      modified,
      original_lines,
      modified_lines,
      self.ignore_tests,
      diff_mode,
    )
    let raw_specialized = match test_ownership {
      Some(ownership) =>
        specialized_diff(
          requested,
          self.ignore_comments,
          self.ignore_tests,
          original,
          modified,
          strict,
          ownership,
        )
      None => None
    }
    let (coverage_valid, coverage_has_ignored) = match
      (raw_specialized, test_ownership) {
      (Some((candidate, _, _)), Some(ownership)) =>
        specialized_source_coverage(
          requested,
          self.ignore_comments,
          self.ignore_tests,
          original,
          modified,
          candidate,
          ownership,
        )
      _ => (false, false)
    }
    let specialized = if coverage_valid { raw_specialized } else { None }
    let whitespace_conflict_is_filtered = coverage_valid && coverage_has_ignored
    if whitespace_conflict && !whitespace_conflict_is_filtered {
      self.status = { requested, effective: Core, fell_back: true, }
      return if options.ignore_trim_whitespace { lenient } else { strict }
    }
    return self.settle_specialized_or_core(
      requested,
      specialized,
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
