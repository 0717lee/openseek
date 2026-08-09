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
/// Creates an empty unified-diff view in a caller-owned stable host element.
pub fn UnifiedDiffView::create(host : @rdom.Element) -> UnifiedDiffView {
  { browser: UnifiedDiffBrowserView(host), disposed: false }
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
  self.browser.set_hunks(
    @unified_diff.compute_unified_diff(
      content_lines(original_content),
      content_lines(modified_content),
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
fn content_lines(content : String) -> Array[String] {
  let snapshot = @model.TextSnapshot(content)
  [
    for index in 0..<snapshot.line_count() => snapshot.line_text(index)
  ]
}
