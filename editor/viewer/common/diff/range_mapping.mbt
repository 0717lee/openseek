// Renderer-neutral mapping values used by both the built-in Core provider and
// external providers. They intentionally expose their representation: a
// provider package must be able to construct validated output without a
// viewer-layer adapter.

///|
/// Maps a half-open line range in the original document to one in the
/// modified document.
pub(all) struct LineRangeMapping {
  original : @base_common.LineRange
  modified : @base_common.LineRange
} derive(Eq, Debug)

///|
pub fn LineRangeMapping::LineRangeMapping(
  original : @base_common.LineRange,
  modified : @base_common.LineRange,
) -> LineRangeMapping {
  { original, modified }
}

///|
/// Maps a one-based UTF-16 range in the original document to one in the
/// modified document.
pub(all) struct RangeMapping {
  original : @base_common.Range
  modified : @base_common.Range
} derive(Eq, Debug)

///|
pub fn RangeMapping::RangeMapping(
  original : @base_common.Range,
  modified : @base_common.Range,
) -> RangeMapping {
  { original, modified }
}

///|
/// Maps a line range in the original text model to a line range in the
/// modified text model, together with the character-level inner range
/// mappings — `DetailedLineRangeMapping` (`rangeMapping.ts:196`). The source
/// class extends `LineRangeMapping`; MoonBit has no inheritance, so the
/// struct is flat and repeats the two line ranges.
pub(all) struct DetailedLineRangeMapping {
  original : @base_common.LineRange
  modified : @base_common.LineRange
  /// If inner changes have not been computed, this is `None`. Otherwise it
  /// represents the character-level diff in this line range.
  inner_changes : Array[RangeMapping]?
} derive(Eq, Debug)

///|
pub fn DetailedLineRangeMapping::DetailedLineRangeMapping(
  original : @base_common.LineRange,
  modified : @base_common.LineRange,
  inner_changes : Array[RangeMapping]?,
) -> DetailedLineRangeMapping {
  { original, modified, inner_changes }
}

///|
/// Character-level changes inside this line mapping, or `None` when the
/// refinement budget was exceeded. This pair projection is convenient for
/// consumers that do not need the named `RangeMapping` fields.
pub fn DetailedLineRangeMapping::get_inner_changes(
  self : DetailedLineRangeMapping,
) -> Array[(@base_common.Range, @base_common.Range)]? {
  self.inner_changes.map(changes => {
    changes.map(change => (change.original, change.modified))
  })
}

///|
pub fn DetailedLineRangeMapping::line_mapping(
  self : DetailedLineRangeMapping,
) -> LineRangeMapping {
  LineRangeMapping(self.original, self.modified)
}

///|
pub extend LineRangeMapping with Debug::{to_repr}

///|
pub extend LineRangeMapping with Eq::{equal, not_equal}

///|
pub extend RangeMapping with Debug::{to_repr}

///|
pub extend RangeMapping with Eq::{equal, not_equal}

///|
pub extend DetailedLineRangeMapping with Debug::{to_repr}

///|
pub extend DetailedLineRangeMapping with Eq::{equal, not_equal}
