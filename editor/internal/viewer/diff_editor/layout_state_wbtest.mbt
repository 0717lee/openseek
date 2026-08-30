///|
test "responsive layout switches exactly at 900/901 without losing preference" {
  let state = DiffEditorLayoutState::DiffEditorLayoutState(DiffEditorOptions())
  state.layout(900.0) |> ignore
  assert_true(state.actual_layout == Inline)
  state.layout(901.0) |> ignore
  assert_true(state.actual_layout == SideBySide)
  state.layout(900.0) |> ignore
  assert_true(state.actual_layout == Inline)
  state.layout(901.0) |> ignore
  assert_true(state.actual_layout == SideBySide)
}

///|
test "explicit Inline is stable above the responsive boundary" {
  let state = DiffEditorLayoutState::DiffEditorLayoutState(
    DiffEditorOptions(layout=Inline),
  )
  state.layout(2000.0) |> ignore
  assert_true(state.actual_layout == Inline)
  assert_true(state.pane_widths() == (0.0, 2000.0))
}

///|
test "sash ratio is clamped to ten through ninety percent" {
  let state = DiffEditorLayoutState::DiffEditorLayoutState(DiffEditorOptions())
  state.layout(1000.0) |> ignore
  assert_true(state.pane_widths() == (500.0, 500.0))
  assert_true(state.set_split_from_pointer(-100.0))
  assert_true(state.pane_widths() == (100.0, 900.0))
  assert_true(state.set_split_from_pointer(2000.0))
  assert_true(state.pane_widths() == (900.0, 100.0))
}

///|
test "disabled sash ignores pointer updates" {
  let state = DiffEditorLayoutState::DiffEditorLayoutState(
    DiffEditorOptions(sash_enabled=false, split_ratio=0.4),
  )
  state.layout(1000.0) |> ignore
  assert_false(state.set_split_from_pointer(750.0))
  assert_true(state.pane_widths() == (400.0, 600.0))
}

///|
test "interactive sash ratio survives unrelated option and layout updates" {
  let state = DiffEditorLayoutState::DiffEditorLayoutState(DiffEditorOptions())
  state.layout(1000.0) |> ignore
  assert_true(state.set_split_from_pointer(700.0))
  state.update_options(DiffEditorOptions(overview_ruler=false)) |> ignore
  assert_true(state.pane_widths() == (700.0, 300.0))
  state.update_options(DiffEditorOptions(layout=Inline, overview_ruler=false))
  |> ignore
  state.update_options(
    DiffEditorOptions(layout=SideBySide, overview_ruler=false),
  )
  |> ignore
  assert_true(state.pane_widths() == (700.0, 300.0))

  state.update_options(DiffEditorOptions(split_ratio=0.6, overview_ruler=false))
  |> ignore
  assert_true(state.pane_widths() == (600.0, 400.0))
}
