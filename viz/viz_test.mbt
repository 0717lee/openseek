// Parsing and the projection's error counts: assertions that hold on either
// backend, so they run wherever `viz` is built. What the two views draw is
// asserted in `viz/render_test`, which renders them to strings through
// rabbita's native-only server-side renderer.

///|
test "rendered_error_count matches the failures each view draws" {
  let failing = @testkit.error_tool_session()
  inspect(@viz.rendered_error_count(failing, RawLog), content="1")
  inspect(@viz.rendered_error_count(failing, ModelView), content="1")
  let clean = @testkit.clean_sample_session()
  inspect(@viz.rendered_error_count(clean, RawLog), content="0")
  inspect(@viz.rendered_error_count(clean, ModelView), content="0")
}

///|
test "model error count excludes a compacted-away failure raw still shows" {
  let compacted = @testkit.compact_second_event(@testkit.error_tool_session())
  // Raw still renders the durable errored result; the model view healed the
  // dangling call, so it has no error card to count.
  inspect(@viz.rendered_error_count(compacted, RawLog), content="1")
  inspect(@viz.rendered_error_count(compacted, ModelView), content="0")
}

///|
test "parse round-trips every event kind" {
  let text = @testkit.events_jsonl(@testkit.sample_session())
  let parsed = @viz.parse_events(text)
  inspect(parsed.events.length(), content="5")
  inspect(parsed.errors.length(), content="0")
  inspect(parsed.partial_tail, content="false")
}

///|
test "parse tolerates a truncated final line" {
  let text = "{\"sequence\":1,\"ts\":0,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\n{\"sequence\":2,\"ts\":0,\"item\":{\"kind\":\"assi"
  let parsed = @viz.parse_events(text)
  inspect(parsed.events.length(), content="1")
  inspect(parsed.errors.length(), content="0")
  inspect(parsed.partial_tail, content="true")
}

///|
test "parse records a bad interior line without aborting" {
  let text = "{\"sequence\":1,\"ts\":0,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\nnot json at all\n{\"sequence\":2,\"ts\":0,\"item\":{\"kind\":\"terminal\",\"payload\":{\"kind\":\"finished\",\"message\":\"done\"}}}\n"
  let parsed = @viz.parse_events(text)
  inspect(parsed.events.length(), content="2")
  inspect(parsed.errors.length(), content="1")
  inspect(parsed.errors[0].line_number, content="2")
  inspect(parsed.partial_tail, content="false")
}

///|
test "the prefetch scanner surfaces a sub-run's child session id" {
  assert_eq(@viz.subrun_child_ids(@testkit.subrun_sample_session(), "run"), [
    "run-sr-2",
  ])
  // An ordinary tool result names no child.
  assert_eq(@viz.subrun_child_ids(@testkit.clean_sample_session(), "demo"), [])
}
