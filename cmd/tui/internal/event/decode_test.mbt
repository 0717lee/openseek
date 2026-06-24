///|
test "decode maps each engine event kind" {
  assert_true(
    @event.decode_event(Json::object({ "event": "agent_step", "step": 3 }))
    is Some(AgentStep),
  )
  assert_true(
    @event.decode_event(Json::object({ "event": "max_steps_exhausted" }))
    is Some(MaxStepsExhausted),
  )
  assert_true(
    @event.decode_event(
      Json::object({ "event": "assistant_delta", "content": "tok" }),
    )
    is Some(AssistantDelta("tok")),
  )
  assert_true(
    @event.decode_event(
      Json::object({ "event": "reasoning_delta", "content": "hmm" }),
    )
    is Some(ReasoningDelta("hmm")),
  )
  assert_true(
    @event.decode_event(
      Json::object({ "event": "reasoning_message", "content": "full thought" }),
    )
    is Some(ReasoningMessage("full thought")),
  )
  assert_true(
    @event.decode_event(
      Json::object({ "event": "agent_finished", "answer": "done" }),
    )
    is Some(AgentFinished("done")),
  )
  assert_true(
    @event.decode_event(
      Json::object({ "event": "runtime_update", "content": "checked: 1 error" }),
    )
    is Some(RuntimeUpdate("checked: 1 error")),
  )
  match
    @event.decode_event(
      Json::object({
        "event": "tool_result",
        "tool_call_id": "c1",
        "tool_name": "bash",
        "is_error": true,
        "content": "boom",
      }),
    ) {
    Some(ToolResult(result)) => {
      assert_eq(result.name, "bash")
      assert_eq(result.content, "boom")
      assert_true(result.is_error)
    }
    _ => fail("expected ToolResult")
  }
}

///|
test "steer wire events decode to their applied and dropped forms" {
  assert_true(
    @event.decode_event(
      Json::object({ "event": "steer_applied", "content": "go left" }),
    )
    is Some(SteerApplied("go left")),
  )
  assert_true(
    @event.decode_event(
      Json::object({ "event": "steer_dropped", "content": "too late" }),
    )
    is Some(SteerDropped("too late")),
  )
}

///|
test "a failed serve turn decodes to a terminal agent error" {
  assert_true(
    @event.decode_event(
      Json::object({ "event": "turn_failed", "error": "DeepSeek API error" }),
    )
    is Some(AgentError("turn failed: DeepSeek API error")),
  )
}

///|
test "a rejected command decodes to a terminal agent error" {
  // An engine that does not understand a command keeps serving and emits no
  // terminal event; decoding the rejection as a terminal error is what closes
  // the run that sent it (e.g. /compact against an older engine).
  assert_true(
    @event.decode_event(
      Json::object({
        "event": "command_error",
        "error": "unknown command: compact",
      }),
    )
    is Some(AgentError("engine rejected command: unknown command: compact")),
  )
}

///|
test "compaction wire events decode to their terminal forms" {
  // Success carries the summary so the controller can preview the new context.
  assert_true(
    @event.decode_event(
      Json::object({
        "event": "compaction_finished",
        "from_sequence": 1,
        "to_sequence": 42,
        "summary": "handoff",
      }),
    )
    is Some(CompactionFinished("handoff")),
  )
  // Failure folds into the general agent-error category like a failed turn.
  assert_true(
    @event.decode_event(
      Json::object({ "event": "compaction_failed", "error": "cancelled" }),
    )
    is Some(AgentError("compaction failed: cancelled")),
  )
  // The start marker carries no controller state, so it drops like any unknown.
  assert_true(
    @event.decode_event(Json::object({ "event": "compaction_started" })) is None,
  )
}

///|
test "decode returns None for a non-object value or unknown event" {
  // `@jsonl` handles blank and malformed lines before decoding; the mapping only
  // has to tolerate a non-object value and a newer engine's unknown event kind.
  assert_true(@event.decode_event(Json::string("not an object")) is None)
  assert_true(
    @event.decode_event(Json::object({ "event": "future_event_kind" })) is None,
  )
}

///|
test "usage total is derived from prompt and completion tokens" {
  match
    @event.decode_event(
      Json::object({
        "event": "usage",
        "prompt_tokens": 100,
        "completion_tokens": 23,
        "cache_hit_tokens": 0,
        "cache_miss_tokens": 100,
      }),
    ) {
    Some(Usage(usage)) => assert_eq(usage.total_tokens, 123)
    _ => fail("expected Usage")
  }
}
