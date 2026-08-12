// Real-browser acceptance for the first side-by-side DiffViewer slice. The
// fixture uses one shared language registry but a scheme-filtered hover
// provider, mirroring Desktop's live-vs-original revision boundary.

///|
priv struct DiffViewerHoverProvider {}

///|
impl @language.HoverProvider for DiffViewerHoverProvider with fn provide_hover(
  _self,
  model,
  position,
  _token,
) {
  let line = model.get_line_content(position.line_number)
  guard line.contains("live_answer") else { return None }
  Some({
    range: Range(
      position.line_number,
      1,
      position.line_number,
      line.length() + 1,
    ),
    contents: [PlainText("hover from the modified revision")],
  })
}

///|
impl @language.DefinitionProvider for DiffViewerHoverProvider with fn provide_definition(
  _self,
  model,
  position,
  _token,
) {
  let line = model.get_line_content(position.line_number)
  if line.contains("use_live_answer") {
    [{ uri: model.uri, range: Range(1, 8, 1, 19) }]
  } else {
    []
  }
}

///|
fn run_diff_viewer_test() -> Unit {
  let ctx = @support.BrowserTestContext("diff_viewer")
  let document = @rdom.document()
  guard document.query_selector("#app").to_option() is Some(app) else {
    ctx.fail("missing #app mount point")
    ctx.finish()
    return
  }
  let shell = document.create_element("main")
  shell.set_attribute("class", "editor-shell diff-viewer-shell")
  shell.set_attribute("data-theme", "dark")
  shell.set_attribute(
    "style", "position:relative;width:900px;height:320px;overflow:hidden;",
  )
  let host = document.create_element("div")
  host.set_attribute("class", "viewer-host diff-viewer-host")
  host.set_attribute("style", "position:absolute;inset:0;")
  shell.append_child(host.as_node())
  app.append_child(shell.as_node())

  let log_service = @log.LogService()
  let languages = @languages.Languages()
  let services = @viewer.ViewerServices(
    languages=languages.language_handle(log_service.log_handle()),
    log_service=log_service.log_handle(),
  )
  languages.set_tokens_provider("moonbit", @lang_moonbit.MoonBitTokenizer())
  |> ignore
  languages.register_hover_provider(
    LanguageFilter(LanguageFilter(language="moonbit", scheme="diff-live")),
    DiffViewerHoverProvider::{  },
  )
  |> ignore
  languages.register_definition_provider(
    LanguageFilter(LanguageFilter(language="moonbit", scheme="diff-live")),
    DiffViewerHoverProvider::{  },
  )
  |> ignore

  let original = @model.TextModel(
    try! @base_common.Uri::from(
      scheme="diff-original",
      authority="fixture",
      path="/main.mbt.md",
    ),
    "main.mbt.md",
    "moonbit",
    1,
    "original-revision",
    diff_viewer_original_source(),
  )
  let modified = @model.TextModel(
    try! @base_common.Uri::from(
      scheme="diff-live",
      authority="fixture",
      path="/main.mbt.md",
    ),
    "main.mbt.md",
    "moonbit",
    2,
    "modified-revision",
    diff_viewer_modified_source(),
  )
  let diff_viewer = @viewer.DiffViewer::create(
    host,
    services~,
    options=ViewerOptions(theme="dark", font_size=12.0, line_height=18.0),
  )
  diff_viewer.set_model(Some(DiffEditorModel(original, modified)))
  @support.set_timeout(
    () => {
      let pane_count = @support.query_count(
        ".diff-viewer-host .moonbit-diff-editor-pane > .monaco-editor",
      )
      let changed_count = @support.query_count(
        ".diff-viewer-host .diff-editor-line-delete, .diff-viewer-host .diff-editor-line-insert",
      )
      let zone_count = @support.query_count(
        ".diff-viewer-host .diff-editor-alignment-zone",
      )
      ctx.metric_int("paneCount", pane_count)
      ctx.metric_int("changedDecorationCount", changed_count)
      ctx.metric_int("alignmentZoneCount", zone_count)
      ctx.assert_true(pane_count == 2, "DiffViewer did not mount two Viewers")
      ctx.assert_true(
        changed_count >= 2,
        "DiffViewer did not render both change decorations",
      )
      ctx.assert_true(
        zone_count >= 1,
        "DiffViewer did not install an alignment ViewZone",
      )
      ctx.finish()
    },
    180,
  )
}

///|
fn diff_viewer_original_source() -> String {
  diff_viewer_source([
    "pub fn live_answer() -> Int {", "  let removed_value = 40", "  removed_value + 2",
    "}", "let alignment_anchor = 1",
  ])
}

///|
fn diff_viewer_modified_source() -> String {
  diff_viewer_source([
    "pub fn live_answer() -> Int {", "  let inserted_value = 41", "  let second_inserted = 1",
    "  inserted_value + second_inserted", "}", "let alignment_anchor = 1",
  ])
}

///|
fn diff_viewer_source(prefix : Array[String]) -> String {
  let source = StringBuilder()
  for index, line in prefix {
    if index > 0 {
      source.write_char('\n')
    }
    source.write_string(line)
  }
  for line in 1..<=80 {
    if line == 45 {
      source.write_string("\nlet use_live_answer = live_answer()")
    } else {
      source.write_string("\nlet shared_line_\{line} = \{line}")
    }
  }
  source.to_string()
}
