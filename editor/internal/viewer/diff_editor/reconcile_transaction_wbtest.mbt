///|
test "reconcile commit uses one generation and fixed synchronous order" {
  let events : Array[String] = ["document-diff"]
  let mut original_generation = -1
  let mut modified_generation = -1
  let mut overview_generation = -1
  commit_diff_reconcile_generation(
    17,
    () => events.push("decorations"),
    generation => {
      original_generation = generation
      events.push("original-view-zones")
    },
    generation => {
      modified_generation = generation
      events.push("modified-view-zones")
    },
    () => events.push("stable-restore"),
    generation => {
      overview_generation = generation
      events.push("overview-ruler")
    },
  )
  assert_eq(original_generation, 17)
  assert_eq(modified_generation, 17)
  assert_eq(overview_generation, 17)
  assert_true(
    events ==
    [
      "document-diff", "decorations", "original-view-zones", "modified-view-zones",
      "stable-restore", "overview-ruler",
    ],
  )
}

///|
test "kernel geometry adapter preserves wrap hidden columns and foreign zones" {
  let geometry = pane_geometry_from_code_editor_parts(
    18.0,
    [
      { line_number: 1, height_in_px: 18.0 },
      { line_number: 2, height_in_px: 36.0 },
      { line_number: 3, height_in_px: 0.0 },
    ],
    [{ after_line_number: 1, height_in_px: 7.0 }],
    [4, 12, 8],
    640.0,
  )
  assert_eq(geometry.line_height(), 18.0)
  assert_eq(geometry.line_count(), 3)
  assert_eq(geometry.content_height(), 61.0)
  assert_eq(geometry.viewport_width(), 640.0)
  assert_true(geometry.line_heights == [18.0, 36.0, 0.0])
  assert_true(geometry.line_max_columns == Some([4, 12, 8]))
  assert_true(
    geometry.foreign_zone_heights() ==
    [{ after_line_number: 1, height_in_px: 7.0 }],
  )
}

///|
test "owned-zone-excluded geometry does not self-trigger another reconcile" {
  let original = PaneGeometrySnapshot(
    3,
    18.0,
    foreign_zone_heights=[{ after_line_number: 2, height_in_px: 9.0 }],
    line_max_columns=[2, 2, 2],
  )
  let same_original = PaneGeometrySnapshot(
    3,
    18.0,
    foreign_zone_heights=[{ after_line_number: 2, height_in_px: 9.0 }],
    line_max_columns=[2, 2, 2],
  )
  let modified = PaneGeometrySnapshot(3, 18.0, line_max_columns=[2, 2, 2])
  assert_false(
    alignment_geometry_pair_changed(
      Some(same_original),
      Some(modified),
      Some(original),
      Some(modified),
    ),
  )

  // A real foreign ViewZone remains in the kernel snapshot and must cause a
  // new geometry transaction; managed/owned zone ids were excluded upstream.
  let with_new_foreign_zone = PaneGeometrySnapshot(
    3,
    18.0,
    foreign_zone_heights=[{ after_line_number: 2, height_in_px: 10.0 }],
    line_max_columns=[2, 2, 2],
  )
  assert_true(
    alignment_geometry_pair_changed(
      Some(with_new_foreign_zone),
      Some(modified),
      Some(original),
      Some(modified),
    ),
  )
}

///|
test "reconcile commit has only the synchronous overview lane after restore" {
  let mut calls = 0
  commit_diff_reconcile_generation(
    3,
    () => calls += 1,
    _generation => calls += 1,
    _generation => calls += 1,
    () => calls += 1,
    _generation => calls += 1,
  )
  assert_eq(calls, 5)
}
