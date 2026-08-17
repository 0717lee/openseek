///|
fn markdown_presentation_test_model(
  path : String,
  language_id : String,
  source : String,
) -> @model.TextModel {
  TextModel(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="markdown-tests",
      path~,
    ),
    path,
    language_id,
    1,
    "markdown-presentation-rev-1",
    source,
  )
}

///|
fn assert_markdown_kind(
  model : @model.TextModel,
  expected_resource_kind : @markdown_core.MarkdownResourceKind,
) -> Unit raise {
  match document_presentation_kind(model) {
    MarkdownDocument(actual) => assert_true(actual == expected_resource_kind)
    CodeDocument => fail("expected Markdown document presentation")
  }
}

///|
test "Markdown presentation classifier is exact over URI path and language id" {
  let ordinary = markdown_presentation_test_model(
    "/README.md", "plaintext", "# ordinary",
  )
  let moonbit = markdown_presentation_test_model(
    "/src/literate.mbt.md", "moonbit", "# literate",
  )
  let untitled = markdown_presentation_test_model(
    "/untitled", "markdown", "# untitled",
  )
  let uppercase = markdown_presentation_test_model(
    "/README.MD", "plaintext", "# code",
  )
  defer {
    ordinary.dispose()
    moonbit.dispose()
    untitled.dispose()
    uppercase.dispose()
  }
  assert_markdown_kind(ordinary, OrdinaryMarkdown)
  assert_markdown_kind(moonbit, MoonBitMarkdown)
  assert_markdown_kind(untitled, OrdinaryMarkdown)
  assert_true(document_presentation_kind(uppercase) is CodeDocument)

  let viewer = Viewer::Viewer()
  viewer.set_model(Some(moonbit))
  assert_false(viewer.is_code_presentation())
  assert_true(viewer.current_browser_presentation() is None)
  viewer.set_model(Some(uppercase))
  assert_true(viewer.is_code_presentation())
  viewer.dispose()
}
