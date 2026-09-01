// Built-in provider factory. Keeping construction explicit lets callers own a
// concrete provider value and coerce it to `&DocumentDiffProvider` only at the
// DiffEditor boundary.

///|
pub fn get_line_document_diff_provider() -> LineDocumentDiffProvider {
  LineDocumentDiffProvider()
}
