///|
/// The auto-compaction trigger reads token usage from API responses, so a
/// mock server drives it with fabricated counts — no giant contexts needed.
/// The main loop always streams SSE while the checkpoint summary call is
/// plain JSON, so replies branch per request.
priv enum MockReply {
  Sse(String)
  Body(Json)
}

///|
async fn auto_compact_test_server(
  group : @async.TaskGroup[Unit],
  handle : (Json) -> MockReply raise,
) -> String? {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0")) catch {
    error => {
      let message = "\{error}"
      if message.contains("Operation not permitted") {
        println("local TCP bind unavailable; skipping auto-compaction test")
        return None
      }
      raise error
    }
  }
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(
      (request, body, conn) => {
        assert_eq(request.path, "/chat/completions")
        match handle(@json.parse(body.read_all().text())) {
          Sse(payload) => {
            conn.send_response(200, "OK", extra_headers={
              "Content-Type": "text/event-stream",
            })
            conn.write("data: \{payload}\n\n")
            conn.write("data: [DONE]\n\n")
          }
          Body(json) => {
            conn.send_response(200, "OK", extra_headers={
              "Content-Type": "application/json",
            })
            conn.write(json.stringify())
          }
        }
      },
      max_connections=8,
    )
  }
  Some("http://127.0.0.1:\{server.addr.port()}/chat/completions")
}

///|
fn usage_json(total_tokens : Int) -> Json {
  {
    "prompt_tokens": total_tokens - 1_000,
    "completion_tokens": 1_000,
    "total_tokens": total_tokens,
  }
}

///|
fn sse_tool_call(id : String, name : String, total_tokens : Int) -> String {
  (
    {
      "choices": [
        {
          "delta": {
            "tool_calls": [
              {
                "index": 0,
                "id": id,
                "type": "function",
                "function": { "name": name, "arguments": "{}" },
              },
            ],
          },
        },
      ],
      "usage": usage_json(total_tokens),
    } : Json).stringify()
}

///|
fn sse_final(content : String, total_tokens : Int) -> String {
  (
    {
      "choices": [{ "delta": { "content": content } }],
      "usage": usage_json(total_tokens),
    } : Json).stringify()
}

///|
fn checkpoint_body(summary : String) -> Json {
  { "choices": [{ "message": { "role": "assistant", "content": summary } }] }
}

///|
fn request_messages(request : Json) -> Array[Json] raise {
  guard request is { "messages": Array(messages), .. } else {
    fail("request without messages: \{request.stringify()}")
  }
  messages
}

///|
fn message_role(message : Json) -> String raise {
  guard message is { "role": String(role), .. } else {
    fail("message without role: \{message.stringify()}")
  }
  role
}

///|
fn message_content(message : Json) -> String raise {
  match message {
    { "content": String(content), .. } => content
    // A tool-call-only assistant message goes out with content: null.
    { "content": Null, .. } => ""
    _ => fail("message without content: \{message.stringify()}")
  }
}

///|
/// The summary call is the only non-streaming request the loop makes; the
/// checkpoint prompt in the last message pins the classification.
fn is_checkpoint_request(request : Json) -> Bool raise {
  let messages = request_messages(request)
  !(request is { "stream": True, .. }) &&
  message_content(messages[messages.length() - 1]).contains(
    "CONTEXT CHECKPOINT COMPACTION",
  )
}

///|
fn probe_tools(results : Array[String]) -> @agent_tool.Tools raise {
  let mut calls = 0
  @agent_tool.Tools([
    AgentToolDefinition(
      name="probe",
      description="Probe tool.",
      schema=JsonSchema({ "type": "object" }),
      execute=Sync(_args => {
        calls += 1
        @agent_tool.ToolAction::respond(results[calls - 1])
      }),
    ),
  ])
}

///|
async test "auto-compaction stage one folds prior turns and keeps the task" {
  @async.with_task_group() <| group => {
    let checkpoint_requests : Array[Json] = []
    let mut main_step = 0
    let mut compacted_request : Json? = None
    let handle = request => {
      if is_checkpoint_request(request) {
        checkpoint_requests.push(request)
        Body(checkpoint_body("PRIOR-SUMMARY"))
      } else {
        main_step += 1
        if main_step == 1 {
          Sse(sse_tool_call("call_probe", "probe", 900_000))
        } else {
          compacted_request = Some(request)
          Sse(sse_final("done", 5_000))
        }
      }
    }
    guard auto_compact_test_server(group, handle) is Some(url) else { return }
    let session = @agent_session.Session(
        SessionId("auto-compact-stage-one"),
        system_prompt="system",
      )
      .append(User(UserMessage("prior question about llamas")))
      .append(Terminal(Finished("prior answer about llamas")))
    let result = @agent.run_turn_in_scope(
      runtime=@agent_runtime.AgentRuntime(),
      scope=@agent_runtime.AgentTaskScope(group),
      api_key="test-key",
      model=Deepseek(V4Flash),
      session~,
      task="TASK-MARKER count the llamas",
      append_item=(session, item) => session.append(item),
      max_steps=3,
      api_url=url,
      tools=probe_tools(["probe-result"]),
    )

    // Durable log: the summary covers exactly the prior turn, and the
    // current turn's events land after it untouched.
    let events = result.events()
    assert_eq(events.length(), 7)
    guard events[3].item() is Summary(summary) else {
      fail("expected summary event")
    }
    assert_eq(summary.from_sequence(), 1)
    assert_eq(summary.to_sequence(), 2)
    assert_eq(summary.content(), "PRIOR-SUMMARY")
    guard events[6].item() is Terminal(Finished(answer)) else {
      fail("expected finished terminal")
    }
    assert_eq(answer, "done")

    // The checkpoint request summarized only the covered prefix: the prior
    // turn is there, the active task is not.
    assert_eq(checkpoint_requests.length(), 1)
    let checkpoint_messages = request_messages(checkpoint_requests[0])
    assert_eq(checkpoint_messages.length(), 4)
    assert_eq(message_role(checkpoint_messages[0]), "system")
    assert_true(message_content(checkpoint_messages[1]).contains("llamas"))
    for message in checkpoint_messages {
      assert_false(message_content(message).contains("TASK-MARKER"))
    }

    // The next main request was re-seeded from the compacted projection:
    // task verbatim, summary in place of the prior turn, tool batch intact.
    guard compacted_request is Some(request) else {
      fail("expected a post-compaction main request")
    }
    let messages = request_messages(request)
    assert_eq(messages.length(), 5)
    assert_eq(message_role(messages[0]), "system")
    assert_eq(message_role(messages[1]), "user")
    assert_true(message_content(messages[1]).contains("TASK-MARKER"))
    assert_eq(message_role(messages[2]), "user")
    assert_true(message_content(messages[2]).contains("[conversation summary]"))
    assert_true(message_content(messages[2]).contains("PRIOR-SUMMARY"))
    assert_eq(message_role(messages[3]), "assistant")
    assert_true(messages[3] is { "tool_calls": Array(_), .. })
    assert_eq(message_role(messages[4]), "tool")
    assert_true(message_content(messages[4]).contains("probe-result"))
    for message in messages {
      assert_false(message_content(message).contains("prior question"))
    }
  }
}

///|
async test "auto-compaction escalates to a full checkpoint once then disarms" {
  @async.with_task_group() <| group => {
    let checkpoint_requests : Array[Json] = []
    let mut main_step = 0
    let mut final_request : Json? = None
    let handle = request => {
      if is_checkpoint_request(request) {
        checkpoint_requests.push(request)
        Body(checkpoint_body("S\{checkpoint_requests.length()}"))
      } else {
        main_step += 1
        match main_step {
          1 => Sse(sse_tool_call("call_1", "probe", 900_000))
          2 => Sse(sse_tool_call("call_2", "probe", 900_000))
          _ => {
            final_request = Some(request)
            Sse(sse_final("done", 900_000))
          }
        }
      }
    }
    guard auto_compact_test_server(group, handle) is Some(url) else { return }
    let session = @agent_session.Session(
        SessionId("auto-compact-escalation"),
        system_prompt="system",
      )
      .append(User(UserMessage("prior question")))
      .append(Terminal(Finished("prior answer")))
    let result = @agent.run_turn_in_scope(
      runtime=@agent_runtime.AgentRuntime(),
      scope=@agent_runtime.AgentTaskScope(group),
      api_key="test-key",
      model=Deepseek(V4Flash),
      session~,
      task="TASK-MARKER keep working",
      append_item=(session, item) => session.append(item),
      max_steps=4,
      api_url=url,
      tools=probe_tools(["result-1", "result-2"]),
    )

    // Stage one folded the prior turn; the persisting pressure escalated to
    // one full-range checkpoint; the third high-usage response triggered
    // nothing more.
    assert_eq(checkpoint_requests.length(), 2)
    let events = result.events()
    assert_eq(events.length(), 10)
    guard events[3].item() is Summary(first) else {
      fail("expected stage-one summary")
    }
    assert_eq(first.from_sequence(), 1)
    assert_eq(first.to_sequence(), 2)
    assert_eq(first.content(), "S1")
    guard events[6].item() is Summary(second) else {
      fail("expected full-range summary")
    }
    assert_eq(second.from_sequence(), 1)
    assert_eq(second.to_sequence(), 6)
    assert_eq(second.content(), "S2")
    guard events[9].item() is Terminal(Finished(answer)) else {
      fail("expected finished terminal")
    }
    assert_eq(answer, "done")

    // After the full checkpoint the model context is just the summary plus
    // the still-open tool batch; even the task folded.
    guard final_request is Some(request) else {
      fail("expected a post-escalation main request")
    }
    let messages = request_messages(request)
    assert_eq(messages.length(), 4)
    assert_eq(message_role(messages[0]), "system")
    assert_eq(message_role(messages[1]), "user")
    assert_true(message_content(messages[1]).contains("S2"))
    assert_eq(message_role(messages[2]), "assistant")
    assert_eq(message_role(messages[3]), "tool")
    assert_true(message_content(messages[3]).contains("result-2"))
    for message in messages {
      assert_false(message_content(message).contains("TASK-MARKER"))
    }
  }
}

///|
async test "auto-compaction guards the final answer at the exact threshold" {
  @async.with_task_group() <| group => {
    let checkpoint_requests : Array[Json] = []
    // 80% of the 1M deepseek-v4-flash window: >= must trigger.
    let handle = request => {
      if is_checkpoint_request(request) {
        checkpoint_requests.push(request)
        Body(checkpoint_body("MONO-SUMMARY"))
      } else {
        Sse(sse_final("boundary done", 800_000))
      }
    }
    guard auto_compact_test_server(group, handle) is Some(url) else { return }
    let session = @agent_session.Session(
      SessionId("auto-compact-boundary"),
      system_prompt="system",
    )
    let result = @agent.run_turn_in_scope(
      runtime=@agent_runtime.AgentRuntime(),
      scope=@agent_runtime.AgentTaskScope(group),
      api_key="test-key",
      model=Deepseek(V4Flash),
      session~,
      task="answer briefly",
      append_item=(session, item) => session.append(item),
      max_steps=1,
      api_url=url,
    )

    // No prior history: the first trigger goes straight to a full
    // checkpoint, appended before the terminal so the next turn starts
    // compacted instead of creeping past the ceiling.
    assert_eq(checkpoint_requests.length(), 1)
    let checkpoint_messages = request_messages(checkpoint_requests[0])
    assert_eq(checkpoint_messages.length(), 3)
    assert_true(
      message_content(checkpoint_messages[1]).contains("answer briefly"),
    )
    let events = result.events()
    assert_eq(events.length(), 3)
    assert_true(events[0].item() is User(_))
    guard events[1].item() is Summary(summary) else {
      fail("expected summary event")
    }
    assert_eq(summary.from_sequence(), 1)
    assert_eq(summary.to_sequence(), 1)
    assert_eq(summary.content(), "MONO-SUMMARY")
    guard events[2].item() is Terminal(Finished(answer)) else {
      fail("expected finished terminal")
    }
    assert_eq(answer, "boundary done")
  }
}

///|
async test "auto-compaction stays quiet below the threshold" {
  @async.with_task_group() <| group => {
    let mut requests = 0
    let handle = request => {
      requests += 1
      assert_false(is_checkpoint_request(request))
      Sse(sse_final("done", 799_999))
    }
    guard auto_compact_test_server(group, handle) is Some(url) else { return }
    let session = @agent_session.Session(
      SessionId("auto-compact-quiet"),
      system_prompt="system",
    )
    let result = @agent.run_turn_in_scope(
      runtime=@agent_runtime.AgentRuntime(),
      scope=@agent_runtime.AgentTaskScope(group),
      api_key="test-key",
      model=Deepseek(V4Flash),
      session~,
      task="answer briefly",
      append_item=(session, item) => session.append(item),
      max_steps=1,
      api_url=url,
    )
    assert_eq(requests, 1)
    let events = result.events()
    assert_eq(events.length(), 2)
    assert_true(events[0].item() is User(_))
    assert_true(events[1].item() is Terminal(Finished(_)))
  }
}

///|
async test "auto-compaction fails open and stops retrying for the turn" {
  @async.with_task_group() <| group => {
    let mut checkpoint_requests = 0
    let mut main_step = 0
    let mut after_failure_request : Json? = None
    let handle = request => {
      if is_checkpoint_request(request) {
        checkpoint_requests += 1
        // An empty summary fails generation client-side without HTTP retries.
        Body(checkpoint_body(""))
      } else {
        main_step += 1
        if main_step == 1 {
          Sse(sse_tool_call("call_probe", "probe", 900_000))
        } else {
          after_failure_request = Some(request)
          Sse(sse_final("done", 900_000))
        }
      }
    }
    guard auto_compact_test_server(group, handle) is Some(url) else { return }
    let session = @agent_session.Session(
      SessionId("auto-compact-fail-open"),
      system_prompt="system",
    )
    let result = @agent.run_turn_in_scope(
      runtime=@agent_runtime.AgentRuntime(),
      scope=@agent_runtime.AgentTaskScope(group),
      api_key="test-key",
      model=Deepseek(V4Flash),
      session~,
      task="TASK-MARKER keep going",
      append_item=(session, item) => session.append(item),
      max_steps=3,
      api_url=url,
      tools=probe_tools(["probe-result"]),
    )

    // One failed attempt disarms the guard: the turn continues on the full
    // history and the second high-usage response asks for no new summary.
    assert_eq(checkpoint_requests, 1)
    let events = result.events()
    assert_eq(events.length(), 4)
    assert_true(events[0].item() is User(_))
    assert_true(events[1].item() is Assistant(_))
    assert_true(events[2].item() is Tool(_))
    guard events[3].item() is Terminal(Finished(answer)) else {
      fail("expected finished terminal")
    }
    assert_eq(answer, "done")
    guard after_failure_request is Some(request) else {
      fail("expected a post-failure main request")
    }
    let messages = request_messages(request)
    assert_eq(messages.length(), 4)
    assert_true(message_content(messages[1]).contains("TASK-MARKER"))
    assert_true(message_content(messages[3]).contains("probe-result"))
  }
}
