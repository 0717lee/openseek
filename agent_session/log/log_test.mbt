///|
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
fn events_jsonl(session : @agent_session.Session) -> String {
  let out = StringBuilder::new()
  for event in session.events() {
    out.write_string(event.to_json().stringify())
    out.write_char('\n')
  }
  out.to_string()
}

///|
test "parse round-trips every event kind" {
  let parsed = @log.parse_events(events_jsonl(sample_session()))
  inspect(parsed.events.length(), content="5")
  inspect(parsed.errors.length(), content="0")
  inspect(parsed.partial_tail, content="false")
}

///|
test "parse tolerates a truncated final line" {
  let text = "{\"sequence\":1,\"ts\":0,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\n{\"sequence\":2,\"ts\":0,\"item\":{\"kind\":\"assi"
  let parsed = @log.parse_events(text)
  inspect(parsed.events.length(), content="1")
  inspect(parsed.errors.length(), content="0")
  inspect(parsed.partial_tail, content="true")
}

///|
test "parse records a bad interior line without aborting" {
  let text = "{\"sequence\":1,\"ts\":0,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\nnot json at all\n{\"sequence\":2,\"ts\":0,\"item\":{\"kind\":\"terminal\",\"payload\":{\"kind\":\"finished\",\"message\":\"done\"}}}\n"
  let parsed = @log.parse_events(text)
  inspect(parsed.events.length(), content="2")
  inspect(parsed.errors.length(), content="1")
  inspect(parsed.errors[0].line_number, content="2")
  inspect(parsed.partial_tail, content="false")
}

///|
test "session from parse uses supplied header values" {
  let session = @log.session_from_parse(
    @log.parse_events(events_jsonl(sample_session())),
    id="demo",
    system_prompt="system",
  )
  assert_eq(session.id().value(), "demo")
  assert_eq(session.system_prompt(), "system")
  assert_eq(session.events().length(), 5)
}
