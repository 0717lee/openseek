///|
fn activity_line_text(state : State) -> String raise {
  guard format_activity_text(state) is Some(text) else {
    fail("expected activity text")
  }
  text.text()
}

///|
test "activity labels streaming and thinking without model text" {
  let state = drain_test_state()
  state.run = Running(@async.now())

  inspect(activity_line_text(state), content="Working (0s)")

  state.stream_phase = ReasoningStreaming
  inspect(activity_line_text(state), content="Thinking (0s)")

  state.stream_phase = ResponseStreaming
  inspect(activity_line_text(state), content="Streaming (0s)")
}

///|
test "pending steer activity segment keeps newest tail" {
  let long = "\{String::make(100, 'y')} tail-end"
  let preview = tail_columns(long, 16)
  assert_true(@displaytext.DisplayText(preview).width() <= 16)
  assert_true(preview.has_prefix("…"))
  assert_true(preview.has_suffix("tail-end"))
}
