///|
/// A scripted DeepSeek stand-in for goal-loop tests: serves `responses` in
/// order (each entry is the SSE lines of one chat completion), records every
/// request body into `request_bodies`, and fails on extra requests.
async fn goal_test_server(
  group : @async.TaskGroup[Unit],
  responses : Array[Array[String]],
  request_bodies : Array[String],
) -> String? {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0")) catch {
    error => {
      let message = "\{error}"
      if message.contains("Operation not permitted") {
        println("local TCP bind unavailable; skipping goal test: \{message}")
        return None
      }
      raise error
    }
  }
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(
      (request, body, conn) => {
        assert_eq(request.path, "/chat/completions")
        let index = request_bodies.length()
        request_bodies.push(body.read_all().text())
        guard index < responses.length() else {
          fail("unexpected model request #\{index + 1}")
        }
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        for line in responses[index] {
          conn.write(line)
        }
        conn.write("data: [DONE]\n\n")
      },
      max_connections=1,
    )
  }
  Some("http://127.0.0.1:\{server.addr.port()}/chat/completions")
}

///|
/// One SSE chunk carrying a single complete tool call plus usage numbers.
fn tool_call_chunk(
  id : String,
  name : String,
  arguments : String,
  prompt_tokens : Int,
  completion_tokens : Int,
) -> String {
  let total = prompt_tokens + completion_tokens
  "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"\{id}\",\"type\":\"function\",\"function\":{\"name\":\"\{name}\",\"arguments\":\"\{arguments}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":\{prompt_tokens},\"completion_tokens\":\{completion_tokens},\"total_tokens\":\{total}}}\n\n"
}

///|
/// One SSE chunk carrying a plain content answer plus usage numbers.
fn content_chunk(
  content : String,
  prompt_tokens : Int,
  completion_tokens : Int,
) -> String {
  let total = prompt_tokens + completion_tokens
  "data: {\"choices\":[{\"delta\":{\"content\":\"\{content}\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":\{prompt_tokens},\"completion_tokens\":\{completion_tokens},\"total_tokens\":\{total}}}\n\n"
}

///|
fn goal_events_of(
  session : @agent_session.Session,
) -> Array[@agent_session.GoalUpdate] {
  let updates = []
  for event in session.events() {
    if event.item() is Goal(update) {
      updates.push(update)
    }
  }
  updates
}

///|
fn internal_events_of(
  session : @agent_session.Session,
) -> Array[@agent_session.InternalContext] {
  let contexts = []
  for event in session.events() {
    if event.item() is Internal(context) {
      contexts.push(context)
    }
  }
  contexts
}

///|
async test "goal loop continues after finish and stops on complete" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      // Turn 1: the model creates the goal, then finishes the turn.
      [
        tool_call_chunk(
          "call_1", "create_goal", "{\\\"objective\\\":\\\"obj-alpha\\\"}", 3, 2,
        ),
      ],
      [content_chunk("turn one done", 4, 1)],
      // Turn 2 (automatic continuation): the model completes the goal.
      [
        tool_call_chunk(
          "call_2", "update_goal", "{\\\"status\\\":\\\"complete\\\"}", 5, 2,
        ),
      ],
      [content_chunk("goal wrapped up", 6, 1)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("goal-complete"),
      system_prompt="system",
    )
    let result = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      session,
      "pursue the objective",
      append_item=(session, item) => session.append(item),
      max_steps=4,
      api_url=url,
    )
    // All four scripted responses were consumed and no more.
    assert_eq(request_bodies.length(), 4)
    // Durable goal lifecycle: Active then Complete, same instance.
    let goals = goal_events_of(result)
    assert_eq(goals.length(), 2)
    assert_true(goals[0].status() is Active)
    assert_true(goals[1].status() is Complete)
    assert_eq(goals[0].goal_id(), goals[1].goal_id())
    // Exactly one hidden continuation, attributed to the goal source.
    let internals = internal_events_of(result)
    assert_eq(internals.length(), 1)
    assert_eq(internals[0].source(), "goal")
    assert_true(internals[0].content().contains("obj-alpha"))
    assert_true(internals[0].content().contains("Completion audit"))
    // The continuation request carried the enveloped internal context.
    assert_true(request_bodies[2].contains("openseek_internal_context"))
    assert_true(request_bodies[2].contains("obj-alpha"))
    // The goal fold agrees the goal finished.
    guard result.current_goal() is Some(snapshot) else { fail("goal") }
    assert_false(snapshot.is_active())
  }
}

///|
async test "goal loop stops when the token budget is exhausted" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      // Turn 1 creates a 5-token goal, then finishes; the two responses
      // together burn well past the budget.
      [
        tool_call_chunk(
          "call_1", "create_goal", "{\\\"objective\\\":\\\"obj-budget\\\",\\\"token_budget\\\":5}",
          3, 2,
        ),
      ],
      [content_chunk("made a dent", 4, 1)],
      // No third response: continuing would fail the test.
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("goal-budget"),
      system_prompt="system",
    )
    let result = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      session,
      "pursue the objective",
      append_item=(session, item) => session.append(item),
      max_steps=4,
      api_url=url,
    )
    assert_eq(request_bodies.length(), 2)
    // The host recorded the budget stop itself; no continuation ran.
    let goals = goal_events_of(result)
    assert_eq(goals.length(), 2)
    assert_true(goals[0].status() is Active)
    assert_true(goals[1].status() is BudgetLimited)
    // The only internal item is the budget-limit notice — no continuation
    // prompt ever rendered.
    let internals = internal_events_of(result)
    assert_eq(internals.length(), 1)
    assert_true(internals[0].content().contains("token budget is exhausted"))
    guard result.current_goal() is Some(snapshot) else { fail("goal") }
    assert_false(snapshot.is_active())
    assert_true(snapshot.goal().is_unfinished())
  }
}

///|
async test "goal loop respects the continuation cap" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      [
        tool_call_chunk(
          "call_1", "create_goal", "{\\\"objective\\\":\\\"obj-cap\\\"}", 3, 2,
        ),
      ],
      [content_chunk("first turn done", 4, 1)],
      // Continuation 1 finishes without updating the goal; the cap stops
      // the loop before a second continuation could request response #4.
      [content_chunk("still working", 5, 1)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("goal-cap"),
      system_prompt="system",
    )
    let result = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      session,
      "pursue the objective",
      append_item=(session, item) => session.append(item),
      max_steps=4,
      max_continuations=1,
      api_url=url,
    )
    assert_eq(request_bodies.length(), 3)
    assert_eq(internal_events_of(result).length(), 1)
    // The goal outlives the run: still active, resumable later.
    guard result.current_goal() is Some(snapshot) else { fail("goal") }
    assert_true(snapshot.is_active())
  }
}

///|
async test "goal loop is a plain turn when no goal is created" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [[content_chunk("ordinary answer", 2, 1)]]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("goal-none"),
      system_prompt="system",
    )
    let result = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      session,
      "just answer",
      append_item=(session, item) => session.append(item),
      max_steps=2,
      api_url=url,
    )
    assert_eq(request_bodies.length(), 1)
    assert_true(result.current_goal() is None)
    assert_eq(internal_events_of(result).length(), 0)
    // The goal tools were advertised even though none was used.
    assert_true(request_bodies[0].contains("\"name\":\"create_goal\""))
  }
}

///|
async test "budget exhaustion stops a turn at the step boundary" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    // The budget window opens at the goal's creating event, so the creation
    // call itself does not count. The second step's usage (9 tokens against
    // a 5-token budget) does — and the NEXT step boundary must end the turn
    // without a third model call; the loop records the budget-limited stop.
    let responses = [
      [
        tool_call_chunk(
          "call_1", "create_goal", "{\\\"objective\\\":\\\"obj-hard\\\",\\\"token_budget\\\":5}",
          3, 2,
        ),
      ],
      [tool_call_chunk("call_2", "get_goal", "{}", 7, 2)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("goal-step-stop"),
      system_prompt="system",
    )
    let result = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      session,
      "pursue the objective",
      append_item=(session, item) => session.append(item),
      max_steps=5,
      api_url=url,
    )
    assert_eq(request_bodies.length(), 2)
    let goals = goal_events_of(result)
    assert_eq(goals.length(), 2)
    assert_true(goals[1].status() is BudgetLimited)
    // The turn closed cleanly at the boundary.
    let events = result.events()
    let mut found_note = false
    for event in events {
      if event.item() is Terminal(Finished(note)) {
        found_note = note.contains("budget is exhausted") || found_note
      }
    }
    assert_true(found_note)
  }
}

///|
async test "host-created goals run and resume without model creation" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      [content_chunk("worked on it", 3, 1)],
      [content_chunk("more progress", 3, 1)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("goal-host"),
      system_prompt="system",
    )
    // --goal path: the host creates the goal before the first turn.
    let result = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      session,
      "pursue the objective",
      append_item=(session, item) => session.append(item),
      objective="host objective",
      max_steps=2,
      max_continuations=1,
      api_url=url,
    )
    assert_eq(request_bodies.length(), 2)
    let goals = goal_events_of(result)
    assert_eq(goals.length(), 1)
    assert_true(goals[0].status() is Active)
    assert_eq(goals[0].objective(), "host objective")
    // The goal precedes the user task in the durable log.
    assert_true(result.events()[0].item() is Goal(_))

    // Re-running --goal against the same session resumes: no new goal event.
    let request_bodies2 : Array[String] = []
    guard goal_test_server(
        group,
        [[content_chunk("resumed", 2, 1)]],
        request_bodies2,
      )
      is Some(url2) else {
      return
    }
    let resumed = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      result,
      "keep going",
      append_item=(session, item) => session.append(item),
      objective="ignored replacement text",
      max_steps=2,
      max_continuations=0,
      api_url=url2,
    )
    assert_eq(request_bodies2.length(), 1)
    let resumed_goals = goal_events_of(resumed)
    assert_eq(resumed_goals.length(), 1)
    assert_eq(resumed_goals[0].objective(), "host objective")
  }
}

///|
async test "unbudgeted goals stop at the default host ceiling" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      // No explicit budget on the goal: the host ceiling governs.
      [
        tool_call_chunk(
          "call_1", "create_goal", "{\\\"objective\\\":\\\"obj-host\\\"}", 3, 2,
        ),
      ],
      // Post-creation spend crosses the (test-sized) host ceiling.
      [content_chunk("expensive turn", 90, 20)],
      // No third response: a continuation would fail the test.
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("goal-host-ceiling"),
      system_prompt="system",
    )
    let result = @agent.run_goal_in_scope(
      runtime,
      scope,
      "test-key",
      V4Flash,
      session,
      "pursue the objective",
      append_item=(session, item) => session.append(item),
      max_steps=4,
      host_token_budget=100,
      api_url=url,
    )
    assert_eq(request_bodies.length(), 2)
    let goals = goal_events_of(result)
    assert_eq(goals.length(), 2)
    assert_true(goals[1].status() is BudgetLimited)
    // The stop left a durable, model-visible explanation.
    let internals = internal_events_of(result)
    assert_eq(internals.length(), 1)
    assert_true(internals[0].content().contains("token budget is exhausted"))
    // The goal-run registry advertises turn-scoped finish wording.
    assert_true(request_bodies[0].contains("End this turn with"))
  }
}
