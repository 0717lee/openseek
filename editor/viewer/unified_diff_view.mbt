///|
/// A standalone readonly unified-diff surface. The host owns source loading
/// and reserves the supplied element for this view; the component owns its DOM
/// subtree and computes presentation hunks through the replaceable algorithm
/// boundary in `viewer/common/unified_diff`.
struct UnifiedDiffView {
  browser : @unified_diff_browser.UnifiedDiffBrowserView
  mut disposed : Bool
}

///|
/// An eager DOM row contains line numbers, a marker, and source text. Keep the
/// standalone renderer below the point where a legal-size short-line document
/// can create enough elements to stall or exhaust the host webview.
const MaxRenderedInputLines = 5000

///|
/// Reject oversized text before `TextSnapshot` normalizes and indexes it. The
/// budget is expressed in UTF-16 code units because `String::length` is an
/// allocation-free O(1) query on the JS target. Checking each side before the
/// subtraction keeps the combined comparison overflow-safe.
const MaxRenderedInputCodeUnits = 1048576

///|
/// Creates an empty unified-diff view in a caller-owned stable host element.
pub fn UnifiedDiffView::create(
  host : @rdom.Element,
  on_comment? : (@unified_diff.UnifiedDiffLineComment) -> Unit,
) -> UnifiedDiffView {
  { browser: UnifiedDiffBrowserView(host, on_comment?), disposed: false }
}

///|
/// Replaces the current comparison. Inputs are normalized with the same text
/// snapshot used by the ordinary Viewer, so CRLF and trailing empty lines have
/// the same meaning in both surfaces.
pub fn UnifiedDiffView::set_diff(
  self : UnifiedDiffView,
  original_content : String,
  modified_content : String,
  context_lines? : Int = 3,
) -> Unit {
  if self.disposed {
    return
  }
  let original_length = original_content.length()
  let modified_length = modified_content.length()
  if original_length > MaxRenderedInputCodeUnits ||
    modified_length > MaxRenderedInputCodeUnits ||
    original_length > MaxRenderedInputCodeUnits - modified_length {
    self.browser.set_message(
      "This diff is too large to render safely. Open the source preview instead.",
    )
    return
  }
  let original = @model.TextSnapshot(original_content)
  let modified = @model.TextSnapshot(modified_content)
  if original.line_count() + modified.line_count() > MaxRenderedInputLines {
    self.browser.set_message(
      "This diff is too large to render safely. Open the source preview instead.",
    )
    return
  }
  self.browser.set_hunks(
    @unified_diff.compute_unified_diff(
      snapshot_lines(original),
      snapshot_lines(modified),
      context_lines~,
    ),
  )
}

///|
/// Removes the current comparison while keeping the view reusable.
pub fn UnifiedDiffView::clear(self : UnifiedDiffView) -> Unit {
  if !self.disposed {
    self.browser.clear()
  }
}

///|
/// Releases renderer-owned DOM. Disposal is idempotent and never removes the
/// caller's host element.
pub fn UnifiedDiffView::dispose(self : UnifiedDiffView) -> Unit {
  if self.disposed {
    return
  }
  self.browser.dispose()
  self.disposed = true
}

///|
fn snapshot_lines(snapshot : @model.TextSnapshot) -> Array[String] {
  [
    for index in 0..<snapshot.line_count() => snapshot.line_text(index)
  ]
}
