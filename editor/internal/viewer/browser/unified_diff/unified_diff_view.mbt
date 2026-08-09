///|
/// Browser-owned DOM for one unified diff. The public facade owns the input
/// contract; this value owns only the subtree installed into its dedicated
/// host element.
struct UnifiedDiffBrowserView {
  host : @rdom.Element
  mut root : @rdom.Element?
  mut disposed : Bool
}

///|
/// Creates an empty renderer. The caller must reserve `host` for this view and
/// must not render its own children into it.
pub fn UnifiedDiffBrowserView::UnifiedDiffBrowserView(
  host : @rdom.Element,
) -> UnifiedDiffBrowserView {
  { host, root: None, disposed: false }
}

///|
/// Replaces the installed diff atomically so callers never expose a mixture
/// of rows from two document generations.
pub fn UnifiedDiffBrowserView::set_hunks(
  self : UnifiedDiffBrowserView,
  hunks : Array[@unified_diff_model.UnifiedDiffHunk],
) -> Unit {
  if self.disposed {
    return
  }
  let next = render_unified_diff(hunks)
  match self.root {
    Some(previous) => self.host.remove_child(previous.as_node())
    None => ()
  }
  self.host.append_child(next.as_node())
  self.root = Some(next)
}

///|
/// Removes rendered rows while retaining the reusable host binding.
pub fn UnifiedDiffBrowserView::clear(self : UnifiedDiffBrowserView) -> Unit {
  if self.disposed {
    return
  }
  match self.root {
    Some(root) => {
      self.host.remove_child(root.as_node())
      self.root = None
    }
    None => ()
  }
}

///|
/// Releases the renderer-owned subtree. Disposal is idempotent and leaves the
/// caller's host element in place.
pub fn UnifiedDiffBrowserView::dispose(self : UnifiedDiffBrowserView) -> Unit {
  if self.disposed {
    return
  }
  self.clear()
  self.disposed = true
}

///|
fn render_unified_diff(
  hunks : Array[@unified_diff_model.UnifiedDiffHunk],
) -> @rdom.Element {
  let document = @rdom.document()
  let root = document.create_element("section")
  root.set_attribute("class", "moonbit-unified-diff")
  root.set_attribute("role", "region")
  root.set_attribute("aria-label", "Unified diff")
  root.set_attribute("tabindex", "0")
  if hunks.is_empty() {
    root.append_child(
      text_element(
        document, "div", "moonbit-unified-diff-empty", "No textual changes.",
      ).as_node(),
    )
    return root
  }
  for hunk_index, hunk in hunks {
    let section = document.create_element("section")
    section.set_attribute("class", "moonbit-unified-diff-hunk")
    section.set_attribute("data-hunk-index", hunk_index.to_string())
    let header = text_element(
      document,
      "div",
      "moonbit-unified-diff-hunk-header",
      hunk_header(hunk),
    )
    header.set_attribute("role", "heading")
    header.set_attribute("aria-level", "2")
    section.append_child(header.as_node())
    for line in hunk.lines {
      section.append_child(render_line(document, line).as_node())
    }
    root.append_child(section.as_node())
  }
  root
}

///|
fn render_line(
  document : @rdom.Document,
  line : @unified_diff_model.UnifiedDiffLine,
) -> @rdom.Element {
  let (kind, marker) = match line.kind {
    Context => ("context", " ")
    Deletion => ("deletion", "-")
    Addition => ("addition", "+")
  }
  let row = document.create_element("div")
  row.set_attribute(
    "class",
    "moonbit-unified-diff-line moonbit-unified-diff-line-\{kind}",
  )
  row.set_attribute("data-line-kind", kind)
  match line.original_line_number {
    Some(number) => row.set_attribute("data-original-line", number.to_string())
    None => ()
  }
  match line.modified_line_number {
    Some(number) => row.set_attribute("data-modified-line", number.to_string())
    None => ()
  }
  let original_number = text_element(
    document,
    "span",
    "moonbit-unified-diff-line-number",
    line.original_line_number.map(number => number.to_string()).unwrap_or(""),
  )
  original_number.set_attribute("aria-hidden", "true")
  let modified_number = text_element(
    document,
    "span",
    "moonbit-unified-diff-line-number",
    line.modified_line_number.map(number => number.to_string()).unwrap_or(""),
  )
  modified_number.set_attribute("aria-hidden", "true")
  let marker_element = text_element(
    document, "span", "moonbit-unified-diff-line-marker", marker,
  )
  row.append_child(original_number.as_node())
  row.append_child(modified_number.as_node())
  row.append_child(marker_element.as_node())
  row.append_child(
    text_element(document, "code", "moonbit-unified-diff-line-text", line.text).as_node(),
  )
  row
}

///|
fn text_element(
  document : @rdom.Document,
  tag : String,
  class_name : String,
  text : String,
) -> @rdom.Element {
  let element = document.create_element(tag)
  element.set_attribute("class", class_name)
  element.append_child(document.create_text_node(text).as_node())
  element
}

///|
fn hunk_header(hunk : @unified_diff_model.UnifiedDiffHunk) -> String {
  "@@ -\{hunk.original_start_line_number},\{hunk.original_line_count} +\{hunk.modified_start_line_number},\{hunk.modified_line_count} @@"
}
