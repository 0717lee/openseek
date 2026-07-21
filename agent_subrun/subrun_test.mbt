///|
/// Local mock-endpoint harness, mirroring the agent package's: the main loop
/// streams SSE, the checkpoint summary call is plain JSON, and fabricated
/// usage counts drive the ceiling machinery.
priv enum MockReply {
  Sse(String)
  Body(Json)
  /// Sleep before replying — long enough that a runner deadline fires first.
  Stall
}

///|
async fn bind_test_server(skip_message : String) -> @http.Server? {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0")) catch {
    error => {
      let message = "\{error}"
      if message.contains("Operation not permitted") {
        println(skip_message)
        return None
      }
      raise error
    }
  }
  Some(server)
}

///|
async fn subrun_test_server(
  group : @async.TaskGroup[Unit],
  handle : (Json) -> MockReply raise,
) -> String? {
  guard bind_test_server("local TCP bind unavailable; skipping subrun test")
    is Some(server) else {
    return None
  }
  group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
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
          Stall => @async.sleep(60_000)
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
/// A streamed tool-call response; each call is (id, name, raw JSON args).
fn sse_tool_calls(
  calls : Array[(String, String, String)],
  total_tokens : Int,
) -> String {
  let entries : Array[Json] = [
    for index, call in calls => {
      let (id, name, arguments) = call
      (
        {
          "index": index,
          "id": id,
          "type": "function",
          "function": { "name": name, "arguments": arguments },
        } : Json)
    }
  ]
  (
    {
      "choices": [{ "delta": { "tool_calls": entries.to_json() } }],
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
fn is_checkpoint_request(request : Json) -> Bool {
  guard request is { "messages": Array(messages), .. } &&
    messages.last() is Some({ "content": String(content), .. }) else {
    return false
  }
  !(request is { "stream": True, .. }) &&
  content.contains("CONTEXT CHECKPOINT COMPACTION")
}

///|
/// The standard spec under test: one `submit` capture tool expecting
/// `{"answer": <string>}`, plus a plain probe tool.
fn answer_spec(
  session_id : String,
  max_steps? : Int = 8,
  wall_deadline_ms? : Int? = None,
) -> @agent_subrun.SubrunSpec[String] {
  {
    session_id,
    system_prompt: "You are a test subagent.",
    task: "Answer via the submit tool.",
    tools: captured => {
      @agent_tool.Tools([
        @agent_subrun.capture_tool(
          name="submit",
          description="Submit the final answer.",
          schema=JsonSchema({ "type": "object" }),
          parse=args => {
            match args {
              { "answer": String(answer), .. } => Ok(answer)
              _ => Err(["answer must be a string"])
            }
          },
          captured,
        ),
        AgentToolDefinition(
          name="probe",
          description="Probe tool.",
          schema=JsonSchema({ "type": "object" }),
          execute=Sync(_args => @agent_tool.ToolAction::respond("result-1")),
        ),
      ])
    },
    max_steps,
    wall_deadline_ms,
  }
}

///|
async fn run_answer_subrun(
  url : String,
  spec : @agent_subrun.SubrunSpec[String],
  event_sink? : @emit.EventSink,
) -> @agent_subrun.SubrunResult[String] {
  @agent_subrun.run_subrun(
    spec,
    api_key="test-key",
    model=Deepseek(V4Flash),
    api_url=url,
    event_sink?,
  )
}

///|
async test "a valid submission captures and accounts cost" {
  @async.with_task_group() <| group => {
    let mut step = 0
    let handle : (Json) -> MockReply raise = _request => {
      step += 1
      if step == 1 {
        Sse(
          sse_tool_calls(
            [("call_1", "submit", "{\"answer\": \"forty-two\"}")],
            100_000,
          ),
        )
      } else {
        Sse(sse_final("should not be reached", 110_000))
      }
    }
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let forwarded : Array[String] = []
    let sink = @emit.EventSink((event, _loc) => {
      guard event.to_json() is Object(fields) &&
        fields.get("event") is Some(String(kind)) else {
        return
      }
      forwarded.push(kind)
    })
    let result = run_answer_subrun(url, answer_spec("capture"), event_sink=sink)
    assert_true(result.value() is Some("forty-two"))
    debug_inspect(result.terminal(), content="Captured")
    assert_eq(result.steps_used(), 1)
    assert_eq(result.prompt_tokens(), 99_000)
    assert_eq(result.completion_tokens(), 1_000)
    // Forwarding is the caller's choice: this sink sees the child's stream.
    assert_true(forwarded.contains("agent_step"))
    assert_true(forwarded.contains("agent_finished"))
  }
}

///|
async test "a rejected submission is retried and then captured" {
  @async.with_task_group() <| group => {
    let mut step = 0
    let handle : (Json) -> MockReply raise = _request => {
      step += 1
      if step == 1 {
        // Invalid: answer is a number, the parse rejects, the model retries.
        Sse(sse_tool_calls([("call_1", "submit", "{\"answer\": 7}")], 100_000))
      } else {
        Sse(
          sse_tool_calls(
            [("call_2", "submit", "{\"answer\": \"second try\"}")],
            110_000,
          ),
        )
      }
    }
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let result = run_answer_subrun(url, answer_spec("retry"))
    assert_true(result.value() is Some("second try"))
    debug_inspect(result.terminal(), content="Captured")
    assert_eq(result.steps_used(), 2)
  }
}

///|
async test "a run that never captures reports NoReport" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> MockReply raise = _request => {
      Sse(sse_final("plain answer, no submit", 100_000))
    }
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let result = run_answer_subrun(url, answer_spec("no-report"))
    assert_true(result.value() is None)
    debug_inspect(result.terminal(), content="NoReport")
  }
}

///|
async test "step exhaustion without a capture reports MaxSteps" {
  @async.with_task_group() <| group => {
    let mut step = 0
    let handle : (Json) -> MockReply raise = _request => {
      step += 1
      Sse(sse_tool_calls([("call_\{step}", "probe", "{}")], 100_000))
    }
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let result = run_answer_subrun(url, answer_spec("max-steps", max_steps=2))
    assert_true(result.value() is None)
    debug_inspect(result.terminal(), content="MaxSteps")
    assert_eq(result.steps_used(), 2)
  }
}

///|
/// The A1 interlock: at the context ceiling a pending capture call is
/// salvaged (control-declared), so the child seals with its report instead
/// of losing it to a skip-close.
async test "a capture at the context ceiling is salvaged" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> MockReply raise = request => {
      if is_checkpoint_request(request) {
        Body({
          "choices": [
            { "message": { "role": "assistant", "content": "SUMMARY" } },
          ],
        })
      } else {
        Sse(
          sse_tool_calls(
            [
              ("call_1", "probe", "{}"),
              ("call_2", "submit", "{\"answer\": \"under pressure\"}"),
            ],
            900_000,
          ),
        )
      }
    }
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let result = run_answer_subrun(url, answer_spec("ceiling-capture"))
    assert_true(result.value() is Some("under pressure"))
    debug_inspect(result.terminal(), content="Captured")
  }
}

///|
async test "a ceiling yield without a capture reports ContextYield" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> MockReply raise = request => {
      if is_checkpoint_request(request) {
        Body({
          "choices": [
            { "message": { "role": "assistant", "content": "SUMMARY" } },
          ],
        })
      } else {
        Sse(sse_tool_calls([("call_1", "probe", "{}")], 900_000))
      }
    }
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let result = run_answer_subrun(url, answer_spec("ceiling-yield"))
    assert_true(result.value() is None)
    debug_inspect(result.terminal(), content="ContextYield")
  }
}

///|
async test "the wall deadline absorbs into TimedOut" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> MockReply raise = _request => Stall
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let result = run_answer_subrun(
      url,
      answer_spec("deadline", wall_deadline_ms=Some(200)),
    )
    assert_true(result.value() is None)
    debug_inspect(result.terminal(), content="TimedOut")
  }
}

///|
/// External cancellation must re-raise, never fold into a terminal: an
/// outer timeout around a deadline-free hanging sub-run gets its None back,
/// which only happens when the cancellation propagated out of run_subrun.
async test "external cancellation re-raises out of the sub-run" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> MockReply raise = _request => Stall
    guard subrun_test_server(group, handle) is Some(url) else { return }
    let outcome = @async.with_timeout_opt(200, () => {
      run_answer_subrun(url, answer_spec("external-cancel"))
    })
    assert_true(outcome is None)
  }
}

///|
async test "a toolset builder failure reports Failed without a run" {
  let spec : @agent_subrun.SubrunSpec[String] = {
    session_id: "bad-tools",
    system_prompt: "sys",
    task: "task",
    tools: _captured => {
      @agent_tool.Tools([
        AgentToolDefinition(
          name="dup",
          description="One.",
          schema=JsonSchema({ "type": "object" }),
          execute=Sync(_args => @agent_tool.ToolAction::respond("1")),
        ),
        AgentToolDefinition(
          name="dup",
          description="Two.",
          schema=JsonSchema({ "type": "object" }),
          execute=Sync(_args => @agent_tool.ToolAction::respond("2")),
        ),
      ])
    },
    max_steps: 3,
    wall_deadline_ms: None,
  }
  let result = @agent_subrun.run_subrun(
    spec,
    api_key="unused",
    model=Deepseek(V4Flash),
    api_url="http://127.0.0.1:1/unused",
  )
  assert_true(result.value() is None)
  guard result.terminal() is Failed(reason) else { fail("expected Failed") }
  assert_true(reason.contains("subrun toolset failed"))
  assert_eq(result.steps_used(), 0)
}
