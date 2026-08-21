// Built-in synchronous document diff provider. It delegates line and scalar
// matching to moonbitlang/core/diff's Myers implementation. This is an
// intentional local algorithm choice, not an emulation of Monaco's advanced
// refinement or timeout/move protocol.

///|
/// Stateless Core-Myers document diff provider.
pub struct CoreDocumentDiffProvider {
  _unit : Unit
} derive(Eq, Debug)

///|
pub fn CoreDocumentDiffProvider::CoreDocumentDiffProvider() -> CoreDocumentDiffProvider {
  { _unit: () }
}

///|
fn snapshot_lines(snapshot : @model.TextSnapshot) -> Array[String] {
  let lines : Array[String] = []
  for line_number in 1..<=snapshot.line_count() {
    lines.push(snapshot.get_line_content(line_number))
  }
  lines
}

///|
pub fn CoreDocumentDiffProvider::compute_diff(
  self : CoreDocumentDiffProvider,
  original : @model.TextSnapshot,
  modified : @model.TextSnapshot,
  options : DocumentDiffOptions,
) -> DocumentDiff {
  self.compute_lines_diff(
    snapshot_lines(original),
    snapshot_lines(modified),
    options,
  )
}

///|
fn CoreDocumentDiffProvider::compute_lines_diff(
  self : CoreDocumentDiffProvider,
  original_lines : Array[String],
  modified_lines : Array[String],
  options : DocumentDiffOptions,
) -> DocumentDiff {
  ignore(self)
  // Normalize before both equality and empty-document handling. Otherwise a
  // whitespace-only logical line and an empty line incorrectly remain a
  // visible change when trim whitespace is ignored.
  let old_input = if options.ignore_trim_whitespace {
    original_lines.map(line => line.trim().to_owned())
  } else {
    original_lines
  }
  let new_input = if options.ignore_trim_whitespace {
    modified_lines.map(line => line.trim().to_owned())
  } else {
    modified_lines
  }
  if old_input == new_input {
    return { changes: [], additional_alignments: [] }
  }

  // Preserve Monaco's useful empty-document shape: its one logical empty line
  // participates in a single whole-document change.
  if (old_input.length() == 1 && old_input[0].length() == 0) ||
    (new_input.length() == 1 && new_input[0].length() == 0) {
    return {
      changes: [
        DetailedLineRangeMapping(
          LineRange(1, original_lines.length() + 1),
          LineRange(1, modified_lines.length() + 1),
          compute_inner_changes(
            original_lines,
            modified_lines,
            LineRange(1, original_lines.length() + 1),
            LineRange(1, modified_lines.length() + 1),
            options.ignore_trim_whitespace,
          ),
        ),
      ],
      additional_alignments: [],
    }
  }

  let d = @core_diff.Diff::Diff(
    old=old_input[:],
    new=new_input[:],
    algorithm=Myers,
  )

  // Convert the flat edit script into hunks: each maximal run of
  // consecutive `Delete`/`Insert` edits (separated by `Equal` runs) is one
  // `DetailedLineRangeMapping`. Core diff emits at most one `Delete` followed
  // by at most one `Insert` per hunk, but the converter tolerates any run.
  let edits = d.edits()
  let changes : Array[DetailedLineRangeMapping] = []
  let mut i = 0
  while i < edits.length() {
    match edits[i] {
      Equal(..) => i += 1
      _ => {
        let mut old_start = 0x7FFFFFFF // 0-based, inclusive
        let mut old_end = -1 // 0-based, exclusive
        let mut new_start = 0x7FFFFFFF
        let mut new_end = -1
        // Where the hunk sits on the side that has no edits: an insert
        // carries the original position it lands after (`old_index`), a
        // delete carries the modified position the gap follows
        // (`new_index`).
        let mut anchor_old = 0
        let mut anchor_new = 0
        while i < edits.length() {
          match edits[i] {
            Equal(..) => break
            Delete(old_index~, old_len~, new_index~) => {
              old_start = old_start.min(old_index)
              old_end = old_end.max(old_index + old_len)
              anchor_new = new_index
            }
            Insert(old_index~, new_index~, new_len~) => {
              new_start = new_start.min(new_index)
              new_end = new_end.max(new_index + new_len)
              anchor_old = old_index
            }
          }
          i += 1
        }
        let original = if old_end >= 0 {
          @base_common.LineRange(old_start + 1, old_end + 1)
        } else {
          LineRange(anchor_old + 1, anchor_old + 1)
        }
        let modified = if new_end >= 0 {
          @base_common.LineRange(new_start + 1, new_end + 1)
        } else {
          LineRange(anchor_new + 1, anchor_new + 1)
        }
        changes.push(
          DetailedLineRangeMapping(
            original,
            modified,
            compute_inner_changes(
              original_lines,
              modified_lines,
              original,
              modified,
              options.ignore_trim_whitespace,
            ),
          ),
        )
      }
    }
  }
  { changes, additional_alignments: [] }
}

///|
pub impl DocumentDiffProvider for CoreDocumentDiffProvider with fn compute_diff(
  self,
  original,
  modified,
  options,
) {
  self.compute_diff(original, modified, options)
}

///|
pub impl DocumentDiffProvider for CoreDocumentDiffProvider with fn on_did_change(
  _self,
  _listener,
) {
  @base_common.Disposable::from(() => ())
}

///|
pub extend CoreDocumentDiffProvider with Debug::{to_repr}

///|
pub extend CoreDocumentDiffProvider with Eq::{equal, not_equal}
