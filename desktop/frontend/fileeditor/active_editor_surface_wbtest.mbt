///|
test "only the visible editor surface participates in host layout" {
  assert_true(
    active_editor_surface_from_visibility(true, false, false, false)
    is Some(CodeEditorSurface),
  )
  assert_true(
    active_editor_surface_from_visibility(false, true, false, false)
    is Some(MarkdownEditorSurface),
  )
  assert_true(
    active_editor_surface_from_visibility(false, false, true, false)
    is Some(DiffEditorSurface),
  )
  assert_true(
    active_editor_surface_from_visibility(false, false, false, false) is None,
  )
  // If a host patch briefly overlaps visibility, the product's most specific
  // comparison surface wins and parked source surfaces remain untouched.
  assert_true(
    active_editor_surface_from_visibility(true, true, true, false)
    is Some(DiffEditorSurface),
  )
  assert_true(
    active_editor_surface_from_visibility(true, true, true, true)
    is Some(SemanticEditorSurface),
  )
}
