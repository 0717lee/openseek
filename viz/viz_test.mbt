// Rabbita 0.15.1 removed the js-target `render_to_string`, so the rendered
// markup of `render_session` / `step_scrubber` / `render_notices` is no longer
// reachable from `moon test`. What remains here is the parse and projection
// surface, which returns data rather than `@html.Html`. See the upgrade note in
// README.mbt.md for the assertions this file used to carry.

///|
/// `sample_session` round-tripped through the durable-log parse path with an
/// empty system prompt — the "clean parsed session" the count tests use.
fn clean_sample_session() -> @agent_session.Session {
  @viz.session_from_parse(
    @viz.parse_events(events_jsonl(sample_session())),
    id="demo",
    system_prompt="",
  )
}

///|
/// Build a session that exercises every event kind, then serialize it back to
/// the on-disk session-file event form so the parser is tested against exactly what
/// the store writes.
fn sample_session() -> @agent_session.Session {
  let s0 = @agent_session.Session(
    SessionId("demo"),
    system_prompt="You are a helpful agent.",
  )
  let s1 = s0.append(User(UserMessage("list the files")))
  let s2 = s1.append(
    Assistant(
      AssistantMessage(
        "I'll run ls.",
        tool_calls=[
          ToolCall(id="call_1", name="shell", arguments="{\"cmd\":\"ls\"}"),
        ],
        reasoning_content="The user wants a directory listing.",
      ),
    ),
  )
  let s3 = s2.append(
    Tool(
      ToolResult(
        tool_call_id="call_1",
        tool_name="shell",
        content="README.md\nsrc",
      ),
    ),
  )
  let s4 = s3.append(Runtime(RuntimeNotice("plan reminder: run tests")))
  s4.append(Terminal(Finished("Here are your files: README.md, src.")))
}

///|
/// Serialize a session to the append-only JSONL text the store persists.
fn events_jsonl(session : @agent_session.Session) -> String {
  let out = StringBuilder()
  for event in session.events() {
    out <+ "\{event.to_json().stringify()}\n"
  }
  out.to_string()
}

///|
/// Compact away the sequence-2 event (a tool result in these fixtures) with a
/// "covered" summary — the projection then heals the call with a synthetic
/// result the model never saw.
fn compact_second_event(
  session : @agent_session.Session,
) -> @agent_session.Session raise {
  session.compact(content="covered", from_sequence=2, to_sequence=2)
}

///|
/// A session whose tool result failed, plus a tool call with arguments and one
/// without.
fn error_tool_session() -> @agent_session.Session {
  @agent_session.Session(SessionId("e"), system_prompt="")
  .append(
    Assistant(
      AssistantMessage("", tool_calls=[
        ToolCall(id="c1", name="shell", arguments="{\"cmd\":\"ls\"}"),
        ToolCall(id="c2", name="noop", arguments="{}"),
      ]),
    ),
  )
  .append(
    Tool(
      ToolResult(
        tool_call_id="c1",
        tool_name="shell",
        content="boom",
        is_error=true,
      ),
    ),
  )
}

///|
/// A parent session holding one explore call/result pair whose brief names
/// sub-run sr-2 — the stamp the explore tool writes on its results.
fn subrun_sample_session() -> @agent_session.Session {
  @agent_session.Session(SessionId("run"), system_prompt="sys")
  .append(User(UserMessage("find the API")))
  .append(
    Assistant(
      AssistantMessage("", tool_calls=[
        ToolCall(id="c1", name="explore", arguments="{\"query\": \"how\"}"),
      ]),
    ),
  )
  .append(
    Tool(
      ToolResult(
        tool_call_id="c1",
        tool_name="explore",
        content="Answer: like this.",
        brief="explore sr-2 (1 citation(s), 7 step(s))",
      ),
    ),
  )
  .append(Terminal(Finished("done")))
}

///|
test "rendered_error_count matches the failures each view draws" {
  let failing = error_tool_session()
  inspect(@viz.rendered_error_count(failing, RawLog), content="1")
  inspect(@viz.rendered_error_count(failing, ModelView), content="1")
  let clean = clean_sample_session()
  inspect(@viz.rendered_error_count(clean, RawLog), content="0")
  inspect(@viz.rendered_error_count(clean, ModelView), content="0")
}

///|
test "model error count excludes a compacted-away failure raw still shows" {
  let compacted = compact_second_event(error_tool_session())
  // Raw still renders the durable errored result; the model view healed the
  // dangling call, so it has no error card to count.
  inspect(@viz.rendered_error_count(compacted, RawLog), content="1")
  inspect(@viz.rendered_error_count(compacted, ModelView), content="0")
}

///|
test "parse round-trips every event kind" {
  let text = events_jsonl(sample_session())
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
  assert_eq(@viz.subrun_child_ids(subrun_sample_session(), "run"), ["run-sr-2"])
  // An ordinary tool result names no child.
  assert_eq(@viz.subrun_child_ids(clean_sample_session(), "demo"), [])
}
