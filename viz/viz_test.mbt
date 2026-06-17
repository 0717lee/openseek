///|
/// Build a session that exercises every event kind, then serialize it back to
/// the on-disk `events.jsonl` form so the parser is tested against exactly what
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
  let s4 = s3.append(Runtime(RuntimeNotice("moon check: 0 errors")))
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
#warnings("-alert_unstable")
fn render(html : @html.Html) -> String {
  @rabbita.render_to_string(@rabbita.static_cell(html))
}

///|
/// A session whose tool result failed, plus a tool call with arguments and one
/// without, to exercise the fold/flag rendering.
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
test "tool calls fold their arguments, empty args stay flat" {
  let html = render(@viz.render_session(error_tool_session(), RawLog))
  // A call with arguments folds: the name becomes a <summary>, args hide in the
  // collapsed <details> (no `open` attribute) yet are still in the DOM.
  assert_true(html.contains("<details class=\"tool-call\">"))
  assert_true(html.contains("<summary class=\"tool-call-name\">"))
  assert_true(html.contains("shell"))
  assert_true(html.contains("cmd"))
  // A call with no meaningful arguments ({}) renders flat — nothing to fold.
  assert_true(
    html.contains("<div class=\"tool-call\"><div class=\"tool-call-name\">"),
  )
}

///|
test "failed tool result is folded and red-flagged" {
  let html = render(@viz.render_session(error_tool_session(), RawLog))
  // Folded by default (a <details> with no `open`), tagged as an error, and the
  // summary carries the red flag so a collapsed failure still stands out.
  assert_true(html.contains("<details class=\"card tool error\">"))
  assert_false(html.contains("<details class=\"card tool error\" open>"))
  assert_true(html.contains("class=\"tool-flag\">🚩 failed"))
  assert_true(html.contains("Tool error · shell"))
  assert_true(html.contains("boom"))
}

///|
test "model view recovers the error flag the projection drops" {
  // The model projection keys a tool message by id only and drops is_error, but
  // the view correlates back to the durable ToolResult, so a failed tool (e.g. a
  // non-zero exit) is red-flagged in the model view too — with its tool name.
  let model = render(@viz.render_session(error_tool_session(), ModelView))
  assert_true(model.contains("<details class=\"card tool error\">"))
  assert_true(model.contains("class=\"tool-flag\">🚩 failed"))
  assert_true(model.contains("Tool error · shell"))
}

///|
test "successful tool result folds without a flag" {
  // sample_session's tool result is a success; it should fold but carry no flag.
  let session = @viz.session_from_parse(
    @viz.parse_events(events_jsonl(sample_session())),
    id="demo",
    system_prompt="",
  )
  let raw = render(@viz.render_session(session, RawLog))
  assert_true(raw.contains("<details class=\"card tool\">"))
  assert_false(raw.contains("tool-flag"))
  // Model view folds its tool result too (no flag — the projection drops it).
  let model = render(@viz.render_session(session, ModelView))
  assert_true(model.contains("<details class=\"card tool\">"))
  assert_true(model.contains("Tool result"))
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
test "raw view renders each event kind" {
  let session = @viz.session_from_parse(
    @viz.parse_events(events_jsonl(sample_session())),
    id="demo",
    system_prompt="You are a helpful agent.",
  )
  let html = render(@viz.render_session(session, RawLog))
  assert_true(html.contains("Turn 1"))
  assert_true(html.contains("class=\"card user\""))
  assert_true(html.contains("class=\"card assistant\""))
  assert_true(html.contains("reasoning"))
  assert_true(html.contains("shell"))
  assert_true(html.contains("Tool result"))
  assert_true(html.contains("Runtime notice"))
  assert_true(html.contains("badge-finished"))
}

///|
test "model view substitutes a summary for the events it covers" {
  // A session whose summary covers the first two events: the model projection
  // should show the summary text and drop the covered user/assistant content.
  let base = @viz.session_from_parse(
    @viz.parse_events(events_jsonl(sample_session())),
    id="demo",
    system_prompt="SYS-PROMPT-MARKER",
  )
  let compacted = base.compact(
    content="SUMMARY-MARKER: user asked for files; agent planned ls.",
    from_sequence=1,
    to_sequence=2,
  )
  let model_html = render(@viz.render_session(compacted, ModelView))
  assert_true(model_html.contains("System prompt"))
  assert_true(model_html.contains("SYS-PROMPT-MARKER"))
  assert_true(model_html.contains("SUMMARY-MARKER"))
  // The assistant's planning line is covered by the summary, so the model view
  // must not replay it.
  assert_true(!model_html.contains("I'll run ls."))
  // The raw view still shows everything, including the covered line.
  let raw_html = render(@viz.render_session(compacted, RawLog))
  assert_true(raw_html.contains("I'll run ls."))
  assert_true(raw_html.contains("Summary"))
}

///|
test "notices surface partial tails and bad lines" {
  let parsed = @viz.parse_events(
    "garbage line\n{\"sequence\":1,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\n{bad tail",
  )
  let html = render(@viz.render_notices(parsed))
  assert_true(html.contains("could not be decoded"))
  assert_true(html.contains("trailing partial line"))
}

///|
/// Stamped events render relative offsets and a turn duration; unstamped
/// events (the 0 sentinel) render no time chips at all.
test "raw view shows per-event offsets and turn duration from ts" {
  let stamped = @agent_session.Session(SessionId("t"), system_prompt="")
    .append(User(UserMessage("go")), unix_ms=1781151318110L)
    .append(Runtime(RuntimeNotice("working")), unix_ms=1781151319242L)
    .append(Terminal(Finished("done")), unix_ms=1781151443650L)
  let html = render(@viz.render_session(stamped, RawLog))
  assert_true(html.contains("+0.0s"))
  assert_true(html.contains("+1.1s"))
  assert_true(html.contains("+2m 05.5s"))
  assert_true(html.contains("· 2m 05.5s"))
  let unstamped = @agent_session.Session(SessionId("u"), system_prompt="")
    .append(User(UserMessage("go")))
    .append(Terminal(Finished("done")))
  let plain = render(@viz.render_session(unstamped, RawLog))
  assert_false(plain.contains("card-ts"))
}
