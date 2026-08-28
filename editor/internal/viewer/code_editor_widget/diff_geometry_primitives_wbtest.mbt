///|
extern "js" fn managed_view_zone_test_element() -> @rdom.Element =
  #| () => ({
  #|   attributes: new Map(),
  #|   setAttribute(name, value) {
  #|     this.attributes.set(String(name), String(value));
  #|   },
  #|   getAttribute(name) {
  #|     return this.attributes.has(String(name))
  #|       ? this.attributes.get(String(name))
  #|       : null;
  #|   },
  #|   removeAttribute(name) {
  #|     this.attributes.delete(String(name));
  #|   },
  #| })

///|
test "diff geometry snapshot follows wrap, hidden lines, and model columns" {
  let options = CodeEditorOptions(font_size=12, line_height=18, soft_wrap=true)
  with_test_viewer(
    (
      #|abcdefghij
      #|hidden
      #|xyz
    ),
    viewer => {
      viewer.test_set_soft_wrap_column(6)
      viewer.set_hidden_areas([Range(2, 1, 2, 1)], source="diff-geometry")
      let snapshot = viewer.geometry_snapshot([]).unwrap()
      assert_eq(snapshot.line_height(), 18.0)
      let heights = snapshot.model_line_heights()
      assert_eq(heights.length(), 3)
      assert_eq(heights[0], { line_number: 1, height_in_px: 36.0, })
      assert_eq(heights[1], { line_number: 2, height_in_px: 0.0, })
      assert_eq(heights[2], { line_number: 3, height_in_px: 18.0, })
      assert_true(snapshot.line_max_columns() == [11, 7, 4])
      assert_eq(snapshot.foreign_zone_heights().length(), 0)
      assert_eq(snapshot.scroll_content().content_height, 54.0)
    },
    options~,
  )
}

///|
test "diff geometry snapshot includes one-read scroll and content facts" {
  with_test_viewer(long_document(200), viewer => {
    viewer.test_set_viewport(width=800.0, height=400.0)
    viewer.set_scroll_position(scroll_top=720.0, scroll_left=0.0)
    let snapshot = viewer.geometry_snapshot([]).unwrap()
    let facts = snapshot.scroll_content()
    assert_eq(facts.scroll_top, 720.0)
    assert_eq(facts.scroll_left, 0.0)
    assert_eq(facts.viewport_width, 800.0)
    assert_eq(facts.viewport_height, 400.0)
    assert_eq(facts.content_height, 3600.0)
    assert_eq(facts.scroll_width, 800.0)
    assert_eq(facts.scroll_height, 3600.0)
    assert_true(facts.content_width >= 0.0)
  })
}

///|
test "diff geometry excludes owned zones but retains foreign zone geometry" {
  let (foreign, excluded_height) = code_editor_foreign_zone_geometry(
    [
      ("owned-a", 2, 19.0),
      ("foreign-a", 2, 7.0),
      ("owned-b", 5, 11.0),
      ("foreign-b", 8, 13.0),
      ("zero", 9, 0.0),
      ("negative", 10, -5.0),
    ],
    ["owned-a", "owned-b"],
  )
  assert_eq(excluded_height, 30.0)
  assert_true(
    foreign ==
    [
      { after_line_number: 2, height_in_px: 7.0, },
      { after_line_number: 8, height_in_px: 13.0, },
    ],
  )
}

///|
test "managed zones replace one generation in exactly one transaction" {
  let first = managed_view_zone_test_element()
  let first_margin = managed_view_zone_test_element()
  let skipped = managed_view_zone_test_element()
  let second = managed_view_zone_test_element()
  let mut transaction_count = 0
  let removed : Array[String] = []
  let added : Array[@editor_browser.ViewZone] = []
  let mut next_id = 0
  let ids = apply_managed_view_zones_transaction(
    ["old-a", "old-b"],
    [
      ManagedCodeEditorViewZoneSpec(
        2,
        19.0,
        first,
        margin_dom_node=first_margin,
        min_width_in_px=512.0,
        ordinal=7,
        suppress_mouse_down=false,
      ),
      ManagedCodeEditorViewZoneSpec(3, 0.0, skipped),
      ManagedCodeEditorViewZoneSpec(5, 7.0, second, show_in_hidden_areas=false),
    ],
    42,
    update => {
      transaction_count += 1
      let accessor = @editor_browser.ViewZoneChangeAccessor::from_callbacks(
        zone => {
          added.push(zone)
          next_id += 1
          "new-\{next_id}"
        },
        id => removed.push(id),
        _id => (),
      )
      try! update(accessor)
    },
  )
  assert_eq(transaction_count, 1)
  assert_true(removed == ["old-a", "old-b"])
  assert_true(ids == ["new-1", "new-2"])
  assert_eq(added.length(), 2)
  assert_eq(added[0].after_line_number, 2)
  assert_true(added[0].height_in_px == Some(19.0))
  assert_true(added[0].show_in_hidden_areas == Some(true))
  assert_true(added[0].suppress_mouse_down == Some(false))
  assert_true(added[0].margin_dom_node is Some(_))
  assert_true(added[0].min_width_in_px == Some(512.0))
  assert_true(added[0].ordinal == Some(7))
  assert_eq(added[1].after_line_number, 5)
  assert_true(added[1].height_in_px == Some(7.0))
  assert_true(added[1].show_in_hidden_areas == Some(false))
  assert_true(added[1].suppress_mouse_down == Some(true))
  assert_eq(
    first.get_attribute("data-managed-view-zone-generation"),
    Some("42"),
  )
  assert_eq(
    first_margin.get_attribute("data-managed-view-zone-generation"),
    Some("42"),
  )
  assert_true(
    skipped.get_attribute("data-managed-view-zone-generation") is None,
  )
  assert_eq(
    second.get_attribute("data-managed-view-zone-generation"),
    Some("42"),
  )
}

///|
test "1000 managed zones teardown in one width-aware transaction" {
  let previous_ids : Array[String] = []
  for index in 0..<1000 {
    previous_ids.push("old-zone-\{index}")
  }
  let mut transaction_count = 0
  let mut layout_count = 0
  let mut remove_count = 0
  let next_ids = apply_managed_view_zones_transaction(previous_ids, [], 18, update => {
    transaction_count += 1
    let accessor = @editor_browser.ViewZoneChangeAccessor::from_callbacks(
      _zone => "unused",
      _id => remove_count += 1,
      _id => layout_count += 1,
    )
    try! update(accessor)
  })
  assert_true(next_ids.is_empty())
  assert_eq(transaction_count, 1)
  assert_eq(layout_count, 1000)
  assert_eq(remove_count, 1000)
}

///|
test "managed zones no-op without an attached browser surface" {
  with_test_viewer("alpha", viewer => {
    let ids = viewer.apply_managed_view_zones(
      ["old"],
      [ManagedCodeEditorViewZoneSpec(1, 18.0, headless_test_element())],
      3,
    )
    assert_eq(ids.length(), 0)
  })
}

///|
test "stable viewport restore keeps a model-line anchor synchronously" {
  with_test_viewer(long_document(100), viewer => {
    viewer.test_set_viewport(width=800.0, height=180.0)
    viewer.set_scroll_position(scroll_top=720.0, scroll_left=0.0)
    let state = viewer.capture_stable_viewport_state().unwrap()
    assert_eq(state.anchor_line_number(), 41)
    assert_eq(state.anchor_viewport_offset(), 0.0)
    assert_eq(state.scroll_left(), 0.0)

    viewer.test_set_layout_view_zones([(2, 30)])
    assert_eq(viewer.get_scroll_top(), 720.0)
    assert_true(viewer.restore_stable_viewport_state(state))
    assert_eq(viewer.get_scroll_top(), 750.0)
  })
}

///|
test "stable viewport restore keeps the wrapped continuation model column" {
  with_test_viewer(
    "abcdefghijklmnopqrstuvwxyz\nnext",
    viewer => {
      viewer.test_set_viewport(width=180.0, height=36.0)
      viewer.test_set_soft_wrap_column(6)
      viewer.set_scroll_top(36.0)
      let state = viewer.capture_stable_viewport_state().unwrap()
      assert_eq(state.anchor_position.line_number, 1)
      assert_eq(state.anchor_position.column, 13)
      assert_eq(state.anchor_viewport_offset(), 0.0)

      viewer.test_set_soft_wrap_column(4)
      assert_true(viewer.restore_stable_viewport_state(state))
      assert_eq(viewer.get_scroll_top(), 54.0)
    },
    options=CodeEditorOptions(soft_wrap=true, font_size=12, line_height=18),
  )
}

///|
test "managed zone reveal uses the exact ordinal-aware zone top" {
  with_test_viewer(long_document(100), viewer => {
    viewer.test_set_viewport(width=800.0, height=180.0)
    let ids : Array[String] = []
    viewer.test_view_model().view_layout.change_whitespace(accessor => {
      ids.push(accessor.insert_whitespace(10, 1, 30.0, 0.0))
      ids.push(accessor.insert_whitespace(10, 2, 40.0, 0.0))
    })
    |> ignore
    assert_eq(ids.length(), 2)
    viewer.set_scroll_top(720.0)
    assert_true(viewer.reveal_managed_view_zone_top(ids[0]))
    assert_eq(viewer.get_scroll_top(), 180.0)
    assert_true(viewer.reveal_managed_view_zone_top(ids[1]))
    assert_eq(viewer.get_scroll_top(), 210.0)
    assert_false(viewer.reveal_managed_view_zone_top("missing-zone"))
  })
}

///|
test "stable viewport state is rejected after a model swap" {
  let viewer = CodeEditorWidget::CodeEditorWidget()
  defer viewer.dispose()
  viewer.set_model(Some(test_model(long_document(50))))
  viewer.test_set_viewport(width=800.0, height=180.0)
  viewer.set_scroll_top(180.0)
  let state = viewer.capture_stable_viewport_state().unwrap()
  viewer.set_model(Some(test_model(long_document(60))))
  assert_false(viewer.restore_stable_viewport_state(state))
  assert_eq(viewer.get_scroll_top(), 0.0)
}

///|
test "diff geometry primitives return no state without a model" {
  let viewer = CodeEditorWidget::CodeEditorWidget()
  defer viewer.dispose()
  assert_true(viewer.geometry_snapshot([]) is None)
  assert_true(viewer.capture_stable_viewport_state() is None)
}
