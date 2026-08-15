///|
/// Build a session that exercises every event kind. Serialized back to the
/// on-disk event form by `events_jsonl`, it is what the parser is tested
/// against — exactly what the store writes.
pub fn sample_session() -> @agent_session.Session {
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
pub fn events_jsonl(session : @agent_session.Session) -> String {
  let out = StringBuilder()
  for event in session.events() {
    out <+ "\{event.to_json().stringify()}\n"
  }
  out.to_string()
}

///|
/// `sample_session` round-tripped through the durable-log parse path with an
/// empty system prompt — the "clean parsed session" the counting and rendering
/// tests use as their no-failures baseline.
pub fn clean_sample_session() -> @agent_session.Session {
  @viz.session_from_parse(
    @viz.parse_events(events_jsonl(sample_session())),
    id="demo",
    system_prompt="",
  )
}

///|
/// Compact away the sequence-2 event (a tool result in these fixtures) with a
/// "covered" summary — the projection then heals the call with a synthetic
/// result the model never saw.
pub fn compact_second_event(
  session : @agent_session.Session,
) -> @agent_session.Session raise {
  session.compact(content="covered", from_sequence=2, to_sequence=2)
}

///|
/// A session whose tool result failed, plus a tool call with arguments and one
/// without, to exercise the fold/flag rendering.
pub fn error_tool_session() -> @agent_session.Session {
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
pub fn subrun_sample_session() -> @agent_session.Session {
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
