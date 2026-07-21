///|
/// The event kind tag of a collected protocol event.
fn event_kind(event : @protocol.Event) -> String {
  guard event.to_json() is Object(fields) &&
    fields.get("event") is Some(String(kind)) else {
    return ""
  }
  kind
}

///|
/// Every protocol event a turn produces flows through the loop's sink —
/// the property a sub-run relies on to keep its lifecycle (most critically
/// `agent_finished`, which the TUI and desktop hosts treat as run-terminal)
/// out of the host-facing stream.
async test "a turn's events all flow through the provided sink" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> MockReply raise = _request => {
      Sse(sse_final("sinked done", 100_000))
    }
    guard auto_compact_test_server(group, handle) is Some(url) else { return }
    let collected : Array[@protocol.Event] = []
    let sink = @emit.EventSink((event, _loc) => collected.push(event))
    let session = @agent_session.Session(
      SessionId("event-sink"),
      system_prompt="system",
    )
    let result = @agent.run_turn_in_scope(
      runtime=AgentRuntime(),
      scope=AgentTaskScope(group),
      api_key="test-key",
      model=Deepseek(V4Flash),
      session~,
      task="answer briefly",
      append_item=(session, item) => session.append(item),
      api_url=url,
      event_sink=sink,
    )
    assert_eq(finished_answer(result), "sinked done")
    let kinds = collected.map(event_kind)
    assert_true(kinds.contains("agent_step"))
    assert_true(kinds.contains("assistant_message"))
    assert_true(kinds.contains("usage"))
    // The terminal arrives at the sink — and, for an isolating sink, ONLY
    // at the sink.
    assert_true(kinds[kinds.length() - 1] is "agent_finished")
  }
}

///|
/// Tool-batch and goal-machinery events route through the sink too — the
/// goal tool's verdict path and the tool-result log share the loop's sink
/// rather than reaching for the process log.
async test "tool and goal events route through the sink" {
  @async.with_task_group() <| group => {
    let mut step = 0
    let handle : (Json) -> MockReply raise = _request => {
      step += 1
      if step == 1 {
        Sse(sse_tool_call("call_1", "probe", 100_000))
      } else {
        Sse(sse_final("all done", 110_000))
      }
    }
    guard auto_compact_test_server(group, handle) is Some(url) else { return }
    let collected : Array[@protocol.Event] = []
    let sink = @emit.EventSink((event, _loc) => collected.push(event))
    let tools : @agent_tool.Tools = Tools([
      AgentToolDefinition(
        name="probe",
        description="Probe tool.",
        schema=JsonSchema({ "type": "object" }),
        execute=Sync(_args => @agent_tool.ToolAction::respond("result-1")),
      ),
    ])
    let session = @agent_session.Session(
      SessionId("event-sink-tools"),
      system_prompt="system",
    )
    let result = @agent.run_turn_in_scope(
      runtime=AgentRuntime(),
      scope=AgentTaskScope(group),
      api_key="test-key",
      model=Deepseek(V4Flash),
      session~,
      task="probe then finish",
      append_item=(session, item) => session.append(item),
      api_url=url,
      tools~,
      event_sink=sink,
    )
    assert_eq(finished_answer(result), "all done")
    let kinds = collected.map(event_kind)
    assert_true(kinds.contains("tool_result"))
    assert_true(kinds.contains("agent_finished"))
  }
}
