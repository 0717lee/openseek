///|
fn public_markdown_viewer_test_model() -> @model.TextModel {
  TextModel(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="markdown-viewer-public-test",
      path="/source.mbt",
    ),
    "source.mbt",
    "moonbit",
    1,
    "public-test-revision",
    "```mbt check\nlet answer = 42\n```",
  )
}

///|
test "public MarkdownViewerWidget model makes resource semantics explicit" {
  let model = public_markdown_viewer_test_model()
  defer model.dispose()
  let ordinary = @markdown_viewer.MarkdownViewerWidgetModel(
    model,
    OrdinaryMarkdown,
  )
  let moonbit = @markdown_viewer.MarkdownViewerWidgetModel(
    model,
    MoonBitMarkdown,
  )
  assert_true(ordinary.model.same(model))
  assert_true(ordinary.resource_kind == OrdinaryMarkdown)
  assert_true(moonbit.model.same(model))
  assert_true(moonbit.resource_kind == MoonBitMarkdown)
}

///|
test "public MarkdownViewerWidget options contain no code-editor policy" {
  let defaults = @markdown_viewer.MarkdownViewerWidgetOptions::default()
  assert_eq(defaults.theme(), "dark")
  assert_eq(defaults.placeholder(), "")
  assert_true(defaults.show_unused())
  let changed = defaults
    .with_theme("light")
    .with_placeholder("Choose a Markdown document")
    .with_show_unused(false)
  assert_eq(changed.theme(), "light")
  assert_eq(changed.placeholder(), "Choose a Markdown document")
  assert_false(changed.show_unused())
}
