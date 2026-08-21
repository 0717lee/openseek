///|
extern "js" fn virtualized_render_lines_test_count(
  element : @rdom.Element,
) -> Int = "(element) => (element.innerHTML.match(/data-rendered-view-line=/g) || []).length"

///|
extern "js" fn virtualized_render_lines_test_html(
  element : @rdom.Element,
) -> String = "(element) => element.innerHTML"

///|
test "virtualized render window clamps top middle end and offscreen" {
  let top = virtualized_render_lines_window(2600, 18.0, 900.0, 0.0, 8)
  assert_eq(top.start_offset, 0)
  assert_eq(top.end_offset_exclusive, 58)
  assert_true(top.visible)
  let middle = virtualized_render_lines_window(2600, 18.0, 900.0, -23400.0, 8)
  assert_eq(middle.start_offset, 1292)
  assert_eq(middle.end_offset_exclusive, 1358)
  assert_true(middle.visible)
  let tail = virtualized_render_lines_window(2600, 18.0, 900.0, -45900.0, 8)
  assert_eq(tail.start_offset, 2542)
  assert_eq(tail.end_offset_exclusive, 2600)
  assert_true(tail.visible)
  let million_pixel_visible = virtualized_render_lines_window(
    100000, 18.0, 900.0, -1000000.0, 8,
  )
  assert_true(million_pixel_visible.visible)
  assert_true(million_pixel_visible.start_offset > 55000)
  let offscreen = virtualized_render_lines_window(
    2600,
    18.0,
    900.0,
    0.0,
    8,
    zone_visible=false,
  )
  assert_eq(offscreen.start_offset, 0)
  assert_eq(offscreen.end_offset_exclusive, 0)
  assert_false(offscreen.visible)
}

///|
test "virtualized render-lines handle keeps a 2600-line zone below 200 DOM rows" {
  with_native_render_lines_test_dom(() => {
    let content = StringBuilder()
    for index in 0..<2600 {
      let wide_suffix = if index == 1300 {
        " // " + "x".repeat(400)
      } else {
        ""
      }
      content.write_string("let original_\{index} = \{index}\{wide_suffix}\n")
    }
    let source = test_model(content.to_string())
    defer source.dispose()
    let options = CodeEditorOptions(font_size=12, line_height=18, tab_size=2)
    with_test_viewer(
      "host",
      viewer => {
        viewer.test_set_viewport(width=800.0, height=900.0)
        let context = viewer
          .create_render_lines_context(source, owner_generation=7)
          .unwrap()
        let rendered = context
          .render_lines(
            @base_common.LineRange(1, 2601),
            line_class_name="diff-editor-inline-deleted-line",
            margin_line_class_name="diff-editor-inline-deleted-line-number",
          )
          .unwrap()
        assert_eq(rendered.view_line_count(), 2600)
        assert_eq(rendered.height_in_px(), 46800.0)
        assert_eq(
          rendered.dom_node().get_attribute("data-render-lines-generation"),
          Some("7"),
        )
        assert_eq(rendered.min_width_in_px(), 0.0)
        assert_eq(virtualized_render_lines_test_count(rendered.dom_node()), 0)
        let spec = rendered.managed_view_zone_spec(0)
        let render_window = spec.on_dom_node_layout.unwrap()
        render_window(true, 0.0)
        assert_true(
          virtualized_render_lines_test_count(rendered.dom_node()) < 200,
        )
        assert_true(
          virtualized_render_lines_test_html(rendered.dom_node()).contains(
            "original_0",
          ),
        )
        let top_min_width = rendered.min_width_in_px()
        assert_true(top_min_width > 0.0)

        render_window(true, -23400.0)
        let middle_html = virtualized_render_lines_test_html(
          rendered.dom_node(),
        )
        assert_true(middle_html.contains("original_1300"))
        assert_true(
          virtualized_render_lines_test_count(rendered.dom_node()) < 200,
        )
        assert_true(
          virtualized_render_lines_test_html(rendered.margin_dom_node()).contains(
            ">1301</div>",
          ),
        )
        let discovered_wide_window = rendered.min_width_in_px()
        assert_true(discovered_wide_window > top_min_width)

        render_window(true, -45900.0)
        let tail_html = virtualized_render_lines_test_html(rendered.dom_node())
        assert_true(tail_html.contains("original_2599"))
        assert_true(
          virtualized_render_lines_test_count(rendered.dom_node()) < 200,
        )
        assert_true(
          virtualized_render_lines_test_html(rendered.margin_dom_node()).contains(
            ">2600</div>",
          ),
        )

        render_window(false, -1000000.0)
        assert_eq(virtualized_render_lines_test_count(rendered.dom_node()), 0)
        assert_eq(rendered.min_width_in_px(), discovered_wide_window)
        rendered.dispose()
        assert_true(rendered.is_disposed())
        context.dispose()
        assert_true(context.is_disposed())
      },
      options~,
    )
  })
}

///|
test "one generation shares one detached ViewModel across 1000 small zones" {
  with_native_render_lines_test_dom(() => {
    let content = StringBuilder()
    for index in 0..<1000 {
      content.write_string("let fragmented_\{index} = \{index}\n")
    }
    let source = test_model(content.to_string())
    defer source.dispose()
    let before = virtualized_render_lines_context_view_model_creations.val
    with_test_viewer("host", viewer => {
      let context = viewer
        .create_render_lines_context(source, owner_generation=91)
        .unwrap()
      let handles : Array[VirtualizedCodeEditorRenderedLines] = []
      for index in 0..<1000 {
        let handle = context
          .render_lines(@base_common.LineRange(index + 1, index + 2))
          .unwrap()
        handle.bind_zone(
          "fragmented-zone-\{index}",
          view_zone(index, handle.dom_node()),
        )
        handles.push(handle)
      }
      assert_eq(
        virtualized_render_lines_context_view_model_creations.val - before,
        1,
      )
      assert_eq(context.owner_generation(), 91)
      assert_eq(context.created_handle_count(), 1000)
      assert_eq(context.live_handle_count(), 1000)
      assert_eq(context.registered_zone_count(), 1000)
      assert_eq(virtualized_render_lines_test_count(handles[0].dom_node()), 0)
      assert_eq(virtualized_render_lines_test_count(handles[999].dom_node()), 0)

      context.dispose()
      assert_true(context.is_disposed())
      assert_eq(context.live_handle_count(), 0)
      assert_eq(context.registered_zone_count(), 0)
      assert_true(handles[0].is_disposed())
      assert_true(handles[999].is_disposed())
    })
  })
}
