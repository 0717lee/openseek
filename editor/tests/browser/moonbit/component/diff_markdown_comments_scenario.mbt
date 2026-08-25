// Real-browser DiffEditor fixture for Markdown-comment contribution policy.
// The public facade owns both kernels; Playwright only selects a source pair,
// switches layout, and resizes the host while observing ordinary pane DOM.

///|
fn diff_markdown_comment_model(
  name : String,
  content : String,
) -> @model.TextModel {
  let uri = @base_common.Uri::from(
    scheme="memory",
    authority="diff-markdown-comments",
    path="/\{name}.mbt",
  ) catch {
    _ => abort("invalid diff Markdown-comment fixture URI")
  }
  TextModel(
    uri,
    "\{name}.mbt",
    "moonbit",
    1,
    "diff-markdown-comments-\{name}",
    content,
  )
}

///|
fn diff_markdown_comment_unchanged_source() -> String {
  (
    #|let before = 1
    #|/// ## Shared comment
    #|/// The same rendered Markdown block is present in both panes.
    #|/// - alpha
    #|/// - beta
    #|let shared_tail = 2
  )
}

///|
fn diff_markdown_comment_original_source() -> String {
  (
    #|let before = 1
    #|/// ## Original comment
    #|/// The old rendered block is intentionally short.
    #|/// old value
    #|let shared_tail = 2
  )
}

///|
fn diff_markdown_comment_modified_source() -> String {
  (
    #|let before = 1
    #|/// ## Modified comment
    #|/// The replacement is deliberately longer so its rich ViewZone has a
    #|/// different measured height after narrow and wide pane layouts.
    #|/// - first replacement item
    #|/// - second replacement item
    #|/// - third replacement item
    #|let shared_tail = 2
  )
}

///|
fn diff_markdown_comment_partial_original_source() -> String {
  (
    #|let before = 1
    #|/// Tiny
    #|/// words
    #|/// stay
    #|/// on
    #|/// one
    #|/// old
    #|let shared_tail = 2
  )
}

///|
fn diff_markdown_comment_partial_modified_source() -> String {
  (
    #|let before = 1
    #|/// Tiny
    #|/// words
    #|/// stay
    #|/// on
    #|/// one
    #|/// new
    #|let shared_tail = 2
  )
}

///|
fn run_diff_markdown_comments_test() -> Unit {
  let document = @rdom.document()
  guard document.query_selector("#app").to_option() is Some(app) else {
    abort("missing #app mount point")
  }
  let host = document.create_element("div")
  host.set_attribute("class", "diff-markdown-comments-host")
  host.set_attribute("style", "display:none;width:1100px;height:640px;")
  app.append_child(host.as_node())

  let log_service = @log.LogService()
  let languages = @languages.Languages()
  languages.set_language_configuration("moonbit", {
    comments: Some({
      line_comment: Some(LineCommentRule("///")),
      block_comment: None,
    }),
    folding_rules: None,
  })
  languages.set_tokens_provider("moonbit", @lang_moonbit.MoonBitTokenizer())
  |> ignore
  let services = @viewer.ViewerServices(
    languages=languages.language_handle(log_service.log_handle()),
    log_service=log_service.log_handle(),
  )
  let editor_options = @viewer.ViewerOptions(
    soft_wrap=true,
    smooth_scrolling=false,
    line_numbers_min_chars=1,
  )
  let diff_editor = @viewer.DiffEditor::create(
    host,
    services~,
    options=@viewer.DiffEditorOptions(
      editor_options~,
      layout=Inline,
      automatic_inline=false,
    ),
  )
  let unchanged_original = diff_markdown_comment_model(
    "unchanged-original",
    diff_markdown_comment_unchanged_source(),
  )
  let unchanged_modified = diff_markdown_comment_model(
    "unchanged-modified",
    diff_markdown_comment_unchanged_source(),
  )
  let replacement_original = diff_markdown_comment_model(
    "replacement-original",
    diff_markdown_comment_original_source(),
  )
  let replacement_modified = diff_markdown_comment_model(
    "replacement-modified",
    diff_markdown_comment_modified_source(),
  )
  let partial_original = diff_markdown_comment_model(
    "partial-original",
    diff_markdown_comment_partial_original_source(),
  )
  let partial_modified = diff_markdown_comment_model(
    "partial-modified",
    diff_markdown_comment_partial_modified_source(),
  )
  diff_editor.set_model(
    Some(@viewer.DiffEditorModel(unchanged_original, unchanged_modified)),
  )
  |> ignore
  let initial_hidden_original_comments = @support.query_count(
    ".diff-markdown-comments-host .moonbit-diff-editor-original .moonbit-viewer-markdown-comment",
  )
  host.set_attribute("style", "width:1100px;height:640px;")
  diff_editor.layout()

  install_diff_markdown_comments_controls(
    initial_hidden_original_comments,
    fixture => {
      let pair = match fixture {
        "replacement" =>
          @viewer.DiffEditorModel(replacement_original, replacement_modified)
        "partial" => @viewer.DiffEditorModel(partial_original, partial_modified)
        _ => @viewer.DiffEditorModel(unchanged_original, unchanged_modified)
      }
      diff_editor.set_model(Some(pair)) |> ignore
    },
    layout_name => {
      let layout : @viewer.DiffEditorLayout = if layout_name == "inline" {
        Inline
      } else {
        SideBySide
      }
      diff_editor.update_options(
        @viewer.DiffEditorOptions(
          editor_options~,
          layout~,
          automatic_inline=false,
        ),
      )
    },
    width => {
      host.set_attribute("style", "width:\{width}px;height:640px;")
      diff_editor.layout()
    },
    () => {
      diff_editor.dispose()
      unchanged_original.dispose()
      unchanged_modified.dispose()
      replacement_original.dispose()
      replacement_modified.dispose()
      partial_original.dispose()
      partial_modified.dispose()
      services.dispose()
    },
  )
}

///|
extern "js" fn install_diff_markdown_comments_controls(
  initial_hidden_original_comments : Int,
  set_fixture : (String) -> Unit,
  set_layout : (String) -> Unit,
  resize : (Int) -> Unit,
  dispose : () -> Unit,
) -> Unit =
  #| (initialHiddenOriginalComments, setFixture, setLayout, resize, dispose) => {
  #|   globalThis.__diffMarkdownCommentsControls = Object.freeze({
  #|     initialHiddenOriginalComments,
  #|     set_fixture: setFixture,
  #|     set_layout: setLayout,
  #|     resize,
  #|     dispose,
  #|   });
  #| }
