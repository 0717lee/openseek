///|
test "line numbers mark the primary model line and skip wrapped continuations" {
  let model = @model.TextModel(
    @base_common.Uri::file("/line-numbers-active.mbt"),
    "line-numbers-active.mbt",
    "plaintext",
    1,
    "line-numbers-active-rev-1",
    "abcdefgh",
  )
  defer model.dispose()
  let view_model = @view_model.ViewModel::with_options(
    model,
    @view_model.ViewModelOptions::soft_wrap(4),
  )
  defer view_model.dispose()
  let viewport = @view_model.viewport_data_from_view_model(
    view_model,
    { start: 1, end: view_model.line_count() + 1, },
    line_height=20,
  )
  let output = prepare_line_numbers_render(
    viewport,
    Some(view_model),
    Some(1),
    left=2.0,
    width=38.0,
  )
  assert_eq(output.length(), 2)
  assert_true(output[0].contains("class=\"line-numbers active-line-number\""))
  assert_true(output[0].contains(">1</div>"))
  assert_eq(output[1], "")
}

///|
test "line numbers leave non-primary model rows inactive" {
  let model = @model.TextModel(
    @base_common.Uri::file("/line-numbers-inactive.mbt"),
    "line-numbers-inactive.mbt",
    "plaintext",
    1,
    "line-numbers-inactive-rev-1",
    "one\ntwo",
  )
  defer model.dispose()
  let view_model = @view_model.ViewModel(model)
  defer view_model.dispose()
  let viewport = @view_model.viewport_data_from_view_model(
    view_model,
    { start: 1, end: 3, },
    line_height=20,
  )
  let output = prepare_line_numbers_render(
    viewport,
    Some(view_model),
    Some(2),
    left=0.0,
    width=40.0,
  )
  assert_false(output[0].contains("active-line-number"))
  assert_true(output[1].contains("active-line-number"))
}
