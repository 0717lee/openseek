///| Headless behavior tests for the `set_value` public API (plan
/// `monaco-set-value-api-port.md`, Tracks D/E) over the `test_viewer`
/// harness: the flush keeps the model / view-model instances (unlike
/// `set_model`'s detach-then-attach), re-fires `onDidChangeModelContent`,
/// marks the rendered content stale, resets the cursor, and the
/// content-change consumers (quick diff, markers) re-derive the decorations
/// the flush destroyed.

///|
test "set_value keeps the model and view model instances" {
  with_test_viewer("one\ntwo", viewer => {
    let model_before = viewer.get_model().unwrap()
    let model_data_generation_before = viewer.model_slot.generation
    viewer.set_value(
      (
        #|a
        #|b
        #|c
      ),
    )
    assert_true(viewer.get_model().unwrap().same(model_before))
    assert_eq(viewer.model_slot.generation, model_data_generation_before)
    assert_eq(
      viewer.get_value(),
      (
        #|a
        #|b
        #|c
      ),
    )
    assert_eq(viewer.test_view_model().line_count(), 3)
  })
}

///|
test "set_value re-fires onDidChangeModelContent with the flush payload" {
  with_test_viewer("one", viewer => {
    let events : Array[@model.ModelContentChangedEvent] = []
    let _sub = viewer.on_did_change_model_content(e => events.push(e))
    viewer.set_value("two\nthree")
    assert_eq(events.length(), 1)
    assert_eq(events[0].is_flush, true)
    assert_eq(events[0].changes.length(), 1)
    assert_eq(viewer.get_value(), "two\nthree")
  })
}

///|
test "set_value without a model is a no-op (cew:490-492)" {
  let viewer = CodeEditorWidget::CodeEditorWidget()
  viewer.set_value("anything")
  assert_true(viewer.get_model() is None)
  viewer.dispose()
}

///|
test "set_value keeps headless scroll while folding recomputes" {
  let before =
    #|root
    #|  before
    #|tail
    #|line 4
    #|line 5
    #|line 6
    #|line 7
    #|line 8
    #|line 9
    #|line 10
    #|line 11
    #|line 12
  let after = before.replace(old="before", new="after ")
  with_test_viewer(before, viewer => {
    viewer.test_set_viewport(width=400.0, height=54.0)
    viewer.set_scroll_top(72.0)
    let scroll_top = viewer.get_scroll_top()
    guard viewer.folding_controller() is Some(controller) else {
      fail("expected a folding controller")
    }
    guard controller.folding_model is Some(folding_before) else {
      fail("expected a folding model before set_value")
    }
    assert_eq(folding_before.regions().length(), 1)

    viewer.set_value(after)

    assert_eq(viewer.get_scroll_top(), scroll_top)
    guard controller.folding_model is Some(folding_after) else {
      fail("expected a folding model after set_value")
    }
    assert_eq(folding_after.regions().length(), 1)
    assert_eq(viewer.get_value(), after)
  })
}

///|
test "set_value preserves the headless model slot without browser state" {
  with_test_viewer("one\ntwo", viewer => {
    guard viewer.model_slot.current is Some(before) else {
      fail("headless model data missing before set_value")
    }
    assert_true(before.browser is None)
    viewer.set_value("a")
    guard viewer.model_slot.current is Some(after) else {
      fail("headless model data missing after set_value")
    }
    assert_true(after.browser is None)
  })
}

///|
test "set_value resets the cursor to the origin" {
  with_test_viewer(
    (
      #|one
      #|two
      #|three
    ),
    viewer => {
      viewer.set_position(Position(3, 2))
      assert_true(viewer.get_position().unwrap() == Position(3, 2))
      viewer.set_value("a\nb")
      assert_true(viewer.get_position().unwrap() == Position(1, 1))
    },
  )
}

///|
test "quick diff re-renders its gutter decorations after a flush (Track E)" {
  let backings = RootTestServiceBackings::new()
  let viewer = CodeEditorWidget::CodeEditorWidget(services=backings.services)
  let model = test_model("alpha\nbravo")
  backings.quick_diff.set_original_content(model.uri, Some("alpha\nbravo"))
  viewer.set_model(Some(model))
  // identical content: no dirty-diff decorations yet
  assert_eq(quick_diff_gutter_decorations(viewer).length(), 0)
  viewer.set_value("alpha\nCHANGED")
  // the contribution's content-change subscription re-ran the decorator
  // against the new snapshot
  assert_eq(quick_diff_gutter_decorations(viewer).length(), 1)
  viewer.dispose()
  backings.dispose()
}

///|
test "marker decorations re-seed after a flush (Track E)" {
  let backings = RootTestServiceBackings::new()
  let viewer = CodeEditorWidget::CodeEditorWidget(services=backings.services)
  let model = test_model("alpha\nbravo")
  // Host diagnostics may predate attachment. Acquiring the model seeds them;
  // ordinary detach and set_value never clear the host-owned store.
  backings.markers.change_one("owner", model.uri, [
    MarkerData(
      severity=Error,
      message="broken",
      start_line_number=1,
      start_column=1,
      end_line_number=1,
      end_column=3,
    ),
  ])
  viewer.set_model(Some(model))
  let marker_handle = backings.marker_decorations.marker_decorations_handle()
  assert_eq(marker_handle.get_live_markers_for_model(model).length(), 1)
  viewer.set_value("alpha\nCHANGED")
  // The service's one per-identity content watch re-seeded the decoration;
  // CodeEditorWidget content delivery does not acquire another lease.
  assert_eq(marker_handle.get_live_markers_for_model(model).length(), 1)
  viewer.dispose()
  backings.dispose()
}
