///|
/// Mock-endpoint harness for the explore executor, mirroring the
/// agent_subrun one: SSE main loop, JSON checkpoint replies unused here.
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
async fn explore_test_server(
  group : @async.TaskGroup[Unit],
  handle : (Json) -> String raise,
) -> String? {
  guard bind_test_server("local TCP bind unavailable; skipping explore test")
    is Some(server) else {
    return None
  }
  group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
    server.run_forever(
      (request, body, conn) => {
        assert_eq(request.path, "/chat/completions")
        let payload = handle(@json.parse(body.read_all().text()))
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        conn.write("data: \{payload}\n\n")
        conn.write("data: [DONE]\n\n")
      },
      max_connections=8,
    )
  }
  Some("http://127.0.0.1:\{server.addr.port()}/chat/completions")
}

///|
fn sse_submit_answer(answer : String, total_tokens : Int) -> String {
  let report : Json = {
    "schema_version": 1,
    "answer": answer,
    "citations": [{ "file": "protocol/event.mbt", "line": 14 }],
  }
  (
    {
      "choices": [
        {
          "delta": {
            "tool_calls": [
              {
                "index": 0,
                "id": "call_1",
                "type": "function",
                "function": {
                  "name": "submit_answer",
                  "arguments": report.stringify(),
                },
              },
            ],
          },
        },
      ],
      "usage": {
        "prompt_tokens": total_tokens - 1_000,
        "completion_tokens": 1_000,
        "total_tokens": total_tokens,
      },
    } : Json).stringify()
}

///|
fn sse_plain(content : String, total_tokens : Int) -> String {
  (
    {
      "choices": [{ "delta": { "content": content } }],
      "usage": {
        "prompt_tokens": total_tokens - 1_000,
        "completion_tokens": 1_000,
        "total_tokens": total_tokens,
      },
    } : Json).stringify()
}

///|
async fn run_explore(
  url : String,
  budget : @agent_subrun.SubrunBudget,
  query : String,
) -> @agent_tool.ToolAction {
  let tool = @agent_explore.definition(
    api_key="test-key",
    model=Deepseek(V4Flash),
    workspace_root=".",
    budget~,
    api_url=url,
  )
  guard tool.execute is Async(execute) else { fail("explore should be async") }
  execute({ "query": query.to_json() })
}

///|
async test "a cited answer renders with budget reconciliation" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> String raise = _request => {
      sse_submit_answer("The Event enum lives in protocol/event.mbt.", 100_000)
    }
    guard explore_test_server(group, handle) is Some(url) else { return }
    let budget = @agent_subrun.SubrunBudget(
      max_calls_per_turn=2,
      max_steps_per_turn=100,
    )
    let action = run_explore(url, budget, "Where is the Event enum defined?")
    guard action is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("The Event enum lives in"))
    assert_true(output.content.contains("- protocol/event.mbt:14"))
    guard output.brief is Some(brief) else { fail("expected a brief") }
    assert_true(brief.contains("1 citation(s)"))
    // The child used 1 step of its 40-step grant: 39 flow back, so a
    // second reservation still gets a full grant from the 100-step turn.
    assert_true(budget.reserve(40) is Some(40))
  }
}

///|
async test "an exhausted budget refuses before launching a child" {
  @async.with_task_group() <| group => {
    let mut requests = 0
    let handle : (Json) -> String raise = _request => {
      requests += 1
      sse_submit_answer("answer", 100_000)
    }
    guard explore_test_server(group, handle) is Some(url) else { return }
    let budget = @agent_subrun.SubrunBudget(
      max_calls_per_turn=1,
      max_steps_per_turn=100,
    )
    let first = run_explore(url, budget, "first question")
    guard first is Respond(output) && !output.is_error else {
      fail("expected the first explore to succeed")
    }
    let second = run_explore(url, budget, "second question")
    guard second is Respond(refused) else { fail("expected Respond") }
    assert_true(refused.is_error)
    assert_true(refused.content.contains("budget exhausted"))
    // The refusal never reached the model endpoint.
    assert_eq(requests, 1)
  }
}

///|
async test "a child that never submits reports no-report gracefully" {
  @async.with_task_group() <| group => {
    let handle : (Json) -> String raise = _request => {
      sse_plain("plain text, no submit", 100_000)
    }
    guard explore_test_server(group, handle) is Some(url) else { return }
    let budget = @agent_subrun.SubrunBudget()
    let action = run_explore(url, budget, "unanswerable")
    guard action is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("produced no report"))
    assert_true(output.content.contains("NoReport"))
  }
}

///|
async test "input validation rejects before spending anything" {
  let budget = @agent_subrun.SubrunBudget(
    max_calls_per_turn=1,
    max_steps_per_turn=100,
  )
  let tool = @agent_explore.definition(
    api_key="unused",
    model=Deepseek(V4Flash),
    workspace_root=".",
    budget~,
    api_url="http://127.0.0.1:1/unused",
  )
  guard tool.execute is Async(execute) else { fail("explore should be async") }
  let action = execute({ "query": "   " })
  guard action is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  // The rejection consumed no budget.
  assert_true(budget.reserve(10) is Some(10))
}
