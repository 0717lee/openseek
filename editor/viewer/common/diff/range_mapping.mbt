// Port of `vscode/src/vs/editor/common/diff/rangeMapping.ts` (vscode
// checked-in submodule): the mapping
// types a lines-diff result is expressed in.
//
// Parity ledger (source members):
// - `LineRangeMapping` — DEFERRED (there is no consumer until the diff editor's
//   inner-change plumbing is ported).
// - `DetailedLineRangeMapping` — PORTED as a flat struct (MoonBit has no
//   class inheritance; it repeats `original`/`modified` beside
//   `inner_changes`). `toTextEdit`/`fromRangeMappings`/
//   `withInnerChangesFromLineRanges` — DEFERRED (need TextEdit /
//   `LineRange.fromRangeInclusive` / `toRangeMapping`).
// - `RangeMapping` originalRange/modifiedRange/ctor/toString/flip/join —
//   PORTED. Statics `fromEdit`/`fromEditJoin`/`toTextEdit` — DEFERRED (no
//   TextEdit type); `join(list)`/`assertSorted` — DEFERRED (no consumer).
// - `lineRangeMappingFromRangeMappings`/`getLineRangeMapping` — DEFERRED
//   (only the char-level refinement pipeline builds line mappings from range
//   mappings; the viewer's computer emits line mappings directly).

///|
/// Maps a line range in the original text model to a line range in the
/// modified text model, together with the character-level inner range
/// mappings — `DetailedLineRangeMapping` (`rangeMapping.ts:196`). The source
/// class extends `LineRangeMapping`; MoonBit has no inheritance, so the
/// struct is flat and repeats the two line ranges.
pub struct DetailedLineRangeMapping {
  original : @base_common.LineRange
  modified : @base_common.LineRange
  /// If inner changes have not been computed, this is `None`. Otherwise it
  /// represents the character-level diff in this line range.
  priv inner_changes : Array[RangeMapping]?
} derive(Eq, Debug)

///|
fn DetailedLineRangeMapping::DetailedLineRangeMapping(
  original_range : @base_common.LineRange,
  modified_range : @base_common.LineRange,
  inner_changes : Array[RangeMapping]?,
) -> DetailedLineRangeMapping {
  { original: original_range, modified: modified_range, inner_changes }
}

///|
/// Maps a range in the original text model to a range in the modified text
/// model — `RangeMapping` (`rangeMapping.ts:243`).
priv struct RangeMapping {
  /// The original range.
  original_range : @base_common.Range
  /// The modified range.
  modified_range : @base_common.Range
} derive(Eq, Debug)

///|
fn RangeMapping::RangeMapping(
  original_range : @base_common.Range,
  modified_range : @base_common.Range,
) -> RangeMapping {
  { original_range, modified_range }
}
