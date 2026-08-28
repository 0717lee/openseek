///|
#warnings("-alert_unstable")
fn render_breadcrumb_html(node : @html.Html) -> String {
  @rabbita.render_to_string(() => @rabbita.Val::constant(node))
}

///|
test "breadcrumb directory renders a VS Code-style file list" {
  let directory = @pathx.Relative("deepseek")
  let file = @pathx.Relative("deepseek/api_key.mbt")
  let children : Map[@pathx.Relative, Array[FileEntry]] = Map([
    (
      directory,
      [
        { name: "docs", path: Relative("deepseek/docs"), is_dir: true, },
        { name: "api_key.mbt", path: file, is_dir: false, },
      ],
    ),
  ])
  let state = { ..owned_state(), children, highlighted: Some(directory), }
  let ctx = { ..test_ctx(), open_files: [file], active_file: Some(file), }
  let html = render_breadcrumb_html(breadcrumb_view(test_emit(), state, ctx))
  assert_true(html.contains("class=\"breadcrumb-picker\""))
  assert_true(html.contains("aria-label=\"Files in deepseek\""))
  assert_true(html.contains("data-path=\"deepseek/docs\""))
  assert_true(html.contains("data-path=\"deepseek/api_key.mbt\""))
  assert_true(html.contains("breadcrumb-picker-icon folder"))
  assert_true(html.contains("breadcrumb-picker-icon file"))
  assert_true(html.contains("breadcrumb-picker-row selected"))
  assert_true(html.contains("aria-expanded=\"true\""))
}

///|
test "breadcrumb directory reports loading and empty folders" {
  let directory = @pathx.Relative("deepseek")
  let ctx = {
    ..test_ctx(),
    active_file: Some(Relative("deepseek/api_key.mbt")),
  }
  let loading = {
    ..owned_state(),
    highlighted: Some(directory),
    loading: [directory],
  }
  let loading_html = render_breadcrumb_html(
    breadcrumb_view(test_emit(), loading, ctx),
  )
  assert_true(loading_html.contains("Loading…"))
  let children : Map[@pathx.Relative, Array[FileEntry]] = Map([(directory, [])])
  let empty = { ..loading, children, loading: [], }
  let empty_html = render_breadcrumb_html(
    breadcrumb_view(test_emit(), empty, ctx),
  )
  assert_true(empty_html.contains("This folder is empty."))
}
