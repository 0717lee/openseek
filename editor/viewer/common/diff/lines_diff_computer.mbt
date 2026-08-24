// Renderer-neutral document diff contract. Unlike the old partial Monaco
// `ILinesDiffComputer` facade, this API describes only behavior implemented by
// this repository: synchronous calculation, trim-whitespace policy, rendered
// changes, and geometry-only alignments.

///|
/// Options shared by all synchronous document diff providers.
pub(all) struct DocumentDiffOptions {
  ignore_trim_whitespace : Bool
} derive(Eq, Debug)

///|
/// A complete document diff. `changes` drive decorations, overview markers,
/// navigation, and alignment. `additional_alignments` affect geometry only;
/// providers use them for source rows deliberately omitted from the visible
/// diff, such as ignored comments. `changes` follow VS Code's canonical hunk
/// invariants: touching rows are grouped, mappings are ordered on both sides,
/// and consecutive hunks have equal unchanged gaps.
pub(all) struct DocumentDiff {
  changes : Array[DetailedLineRangeMapping]
  additional_alignments : Array[LineRangeMapping]
} derive(Eq, Debug)

///|
/// Synchronous, renderer-neutral document diff provider. Providers may raise
/// when calculation fails; the owning diff ViewModel is responsible for
/// converting that failure into its `Failed` state.
pub(open) trait DocumentDiffProvider {
  fn compute_diff(
    Self,
    @model.TextSnapshot,
    @model.TextSnapshot,
    DocumentDiffOptions,
  ) -> DocumentDiff raise

  /// Notifies the owner that provider configuration changed and the current
  /// model pair must be recomputed. Immutable providers return a no-op
  /// disposable and never invoke the listener.
  fn on_did_change(Self, () -> Unit) -> @base_common.Disposable
}

///|
pub extend DocumentDiff with Debug::{to_repr}

///|
pub extend DocumentDiff with Eq::{equal, not_equal}

///|
pub extend DocumentDiffOptions with Debug::{to_repr}

///|
pub extend DocumentDiffOptions with Eq::{equal, not_equal}
