///|
test "whole-margin decoration builder emits one full-margin piece per class" {
  let output = prepare_margin_decorations_render([
    ["diff-editor-gutter-delete"],
    [],
    ["alpha", "beta"],
  ])
  assert_eq(
    output[0],
    "<div class=\"cmdr diff-editor-gutter-delete\" style=\"\"></div>",
  )
  assert_eq(output[1], "")
  assert_eq(
    output[2],
    "<div class=\"cmdr alpha\" style=\"\"></div><div class=\"cmdr beta\" style=\"\"></div>",
  )
}

///|
test "whole-margin decoration collector ignores the marker lane" {
  let with_margin : @view_model.ViewModelDecoration = {
    range: Range(4, 1, 6, 1),
    options: ModelDecorationOptions(
      "line-delete",
      margin_class_name="diff-editor-gutter-delete",
      z_index=7,
    ),
  }
  let lane_only : @view_model.ViewModelDecoration = {
    range: Range(5, 1, 5, 1),
    options: ModelDecorationOptions(
      "",
      lines_decorations_class_name="delete-sign codicon-diff-remove",
    ),
  }
  let rendered = margin_decorations_to_render([lane_only, with_margin])
  assert_eq(rendered.length(), 1)
  assert_eq(rendered[0].start_line_number, 4)
  assert_eq(rendered[0].end_line_number, 6)
  assert_eq(rendered[0].class_name, "diff-editor-gutter-delete")
}
