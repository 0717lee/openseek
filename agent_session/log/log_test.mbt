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
  // Serializing the sample session and parsing it back recovers all five event
  // kinds (user, assistant-with-tool-call, tool, runtime, terminal) with no
  // errors and no partial tail.
  debug_inspect(
    @log.parse_events(events_jsonl(sample_session())),
    content=(
      #|{
      #|  header: None,
      #|  events: [
      #|    { sequence: 1, ts: 0, item: User({ content: "list the files" }) },
      #|    {
      #|      sequence: 2,
      #|      ts: 0,
      #|      item: Assistant(
      #|        {
      #|          content: "I'll run ls.",
      #|          tool_calls: [{ id: "call_1", name: "shell", arguments: "{\"cmd\":\"ls\"}" }],
      #|          reasoning_content: Some("The user wants a directory listing."),
      #|        },
      #|      ),
      #|    },
      #|    {
      #|      sequence: 3,
      #|      ts: 0,
      #|      item: Tool(
      #|        {
      #|          tool_call_id: "call_1",
      #|          tool_name: "shell",
      #|          content: "README.md\nsrc",
      #|          is_error: false,
      #|          brief: None,
      #|        },
      #|      ),
      #|    },
      #|    {
      #|      sequence: 4,
      #|      ts: 0,
      #|      item: Runtime({ content: "moon check: 0 errors" }),
      #|    },
      #|    {
      #|      sequence: 5,
      #|      ts: 0,
      #|      item: Terminal(Finished("Here are your files: README.md, src.")),
      #|    },
      #|  ],
      #|  errors: [],
      #|  partial_tail: false,
      #|}
    ),
  )
}

///|
test "parse tolerates a truncated final line" {
  // A half-written last line (a crash mid-append) is dropped, the preceding
  // events survive, and partial_tail flags the truncation.
  let text = "{\"sequence\":1,\"ts\":0,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\n{\"sequence\":2,\"ts\":0,\"item\":{\"kind\":\"assi"
  debug_inspect(
    @log.parse_events(text),
    content=(
      #|{
      #|  header: None,
      #|  events: [{ sequence: 1, ts: 0, item: User({ content: "hi" }) }],
      #|  errors: [],
      #|  partial_tail: true,
      #|}
    ),
  )
}

///|
test "parse records a bad interior line without aborting" {
  // A corrupt interior line is recorded while the valid events on either side
  // still parse. We snapshot the surviving events and the error's line number
  // and original text, but not the parser's `message` — that wording belongs to
  // moonbitlang/core and should not be pinned here.
  let text = "{\"sequence\":1,\"ts\":0,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\nnot json at all\n{\"sequence\":2,\"ts\":0,\"item\":{\"kind\":\"terminal\",\"payload\":{\"kind\":\"finished\",\"message\":\"done\"}}}\n"
  let parsed = @log.parse_events(text)
  debug_inspect(
    parsed.events,
    content=(
      #|[
      #|  { sequence: 1, ts: 0, item: User({ content: "hi" }) },
      #|  { sequence: 2, ts: 0, item: Terminal(Finished("done")) },
      #|]
    ),
  )
  debug_inspect(
    parsed.errors.map(e => (e.line_number, e.content)),
    content=(
      #|[(2, "not json at all")]
    ),
  )
  inspect(
    parsed.partial_tail,
    content=(
      #|false
    ),
  )
}

///|
test "parse lifts the header record from the first line" {
  // A session file as the store writes it: header line first, events after.
  let header : @log.SessionFileHeader = {
    id: "demo",
    system_prompt: "You are a helpful agent.",
  }
  let text = "\{header.to_json().stringify()}\n\{events_jsonl(sample_session())}"
  let parsed = @log.parse_events(text)
  debug_inspect(
    parsed.header,
    content=(
      #|Some({ id: "demo", system_prompt: "You are a helpful agent." })
    ),
  )
  assert_eq(parsed.events.length(), 5)
  assert_eq(parsed.errors.length(), 0)
  // A header record is only recognized on the first content line; later
  // header-shaped lines are ordinary bad lines.
  let trailing = "\{events_jsonl(sample_session())}\{header.to_json().stringify()}\n"
  let reparsed = @log.parse_events(trailing)
  debug_inspect(reparsed.header, content="None")
  assert_eq(reparsed.events.length(), 5)
  assert_eq(reparsed.errors.length(), 1)
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
