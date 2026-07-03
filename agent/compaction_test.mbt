///|
/// Auto-compaction tests against the scripted DeepSeek stand-in from
/// `goal_loop_test.mbt` (test files in one package share definitions).
async test "auto-compaction summarizes at the step boundary and rebuilds the projection" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      // Step 1: prompt usage above the threshold plus a tool call, so the
      // turn survives to the next step boundary.
      [
        tool_call_chunk(
          "call_1", "read", "{\\\"path\\\":\\\"missing-compaction-probe.txt\\\"}",
          150, 10,
        ),
      ],
      // The auto-compaction request: the summarizer's answer.
      [content_chunk("checkpoint summary of prior work", 40, 12)],
      // Step 2: the model finishes the turn.
      [content_chunk("done", 5, 1)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let session = @agent_session.Session(
      SessionId("compact-turn"),
      system_prompt="system",
    )
    let result = @agent.run_turn_with_append(
      "test-key",
      V4Flash,
      session,
      "task-alpha",
      append_item=(session, item) => session.append(item),
      max_steps=4,
      api_url=url,
      compact_threshold=100,
    )
    assert_eq(request_bodies.length(), 3)
    // The compaction request carries the checkpoint prompt; without a goal
    // there is no objective section.
    assert_true(request_bodies[1].contains("CONTEXT CHECKPOINT COMPACTION"))
    assert_false(request_bodies[1].contains("<objective>"))
    // The post-compaction step projects the summary instead of the covered
    // history: the original user task no longer reaches the model.
    assert_true(request_bodies[2].contains("checkpoint summary of prior work"))
    assert_false(request_bodies[2].contains("task-alpha"))
    // Durable shape mirrors `compact_session`: the summarizer's own usage is
    // recorded first, then the summary terminates the covered range.
    let events = result.events()
    let mut summary_index = -1
    let mut cursor = 0
    for event in events {
      if event.item() is Summary(_) {
        summary_index = cursor
      }
      cursor += 1
    }
    guard summary_index >= 1 else { fail("expected a summary event") }
    guard events[summary_index].item() is Summary(summary) else {
      fail("expected a summary item")
    }
    assert_eq(summary.from_sequence(), 1)
    guard events[summary_index - 1].item() is Usage(_) else {
      fail("expected the summarizer usage event before the summary")
    }
    // The summary covers everything before the summarizer usage event.
    assert_eq(summary.to_sequence(), events[summary_index - 1].sequence() - 1)
    guard events[events.length() - 1].item() is Terminal(Finished(answer)) else {
      fail("expected a finished terminal")
    }
    assert_eq(answer, "done")
  }
}

///|
async test "goal turns pass the objective into auto-compaction" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      // Turn step 1: prompt usage above the threshold plus a tool call.
      [
        tool_call_chunk(
          "call_1", "read", "{\\\"path\\\":\\\"missing-goal-probe.txt\\\"}", 150,
          10,
        ),
      ],
      // The auto-compaction request.
      [content_chunk("goal checkpoint summary", 20, 8)],
      // Step 2: the model completes the goal.
      [
        tool_call_chunk(
          "call_2", "update_goal", "{\\\"status\\\":\\\"complete\\\"}", 6, 2,
        ),
      ],
      // Step 3: the model finishes the turn; the run ends on Complete.
      [content_chunk("goal wrapped up", 6, 1)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("compact-goal"),
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
      objective="obj-compaction",
      max_steps=6,
      max_continuations=1,
      api_url=url,
      compact_threshold=100,
    )
    assert_eq(request_bodies.length(), 4)
    // The summarizer sees the active goal's objective, enveloped.
    assert_true(request_bodies[1].contains("CONTEXT CHECKPOINT COMPACTION"))
    assert_true(request_bodies[1].contains("<objective>"))
    assert_true(request_bodies[1].contains("obj-compaction"))
    // The goal completed durably despite the mid-turn compaction.
    let goals = goal_events_of(result)
    assert_true(goals[goals.length() - 1].status() is Complete)
  }
}

///|
async test "a continuation turn compacts before its first model call" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      // Turn 1: a single over-threshold response finishes the turn — no
      // step boundary ever sees it, so only the seeded next turn can react.
      [content_chunk("worked on it", 150, 10)],
      // Continuation turn, step 0: the seeded trigger compacts first.
      [content_chunk("continuation checkpoint", 20, 5)],
      // Continuation turn, step 0 model call: complete the goal.
      [
        tool_call_chunk(
          "call_1", "update_goal", "{\\\"status\\\":\\\"complete\\\"}", 6, 2,
        ),
      ],
      [content_chunk("all done", 6, 1)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("compact-continuation"),
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
      objective="obj-continuation",
      max_steps=4,
      max_continuations=1,
      api_url=url,
      compact_threshold=100,
    )
    assert_eq(request_bodies.length(), 4)
    // Request 1 is the summarizer; request 2 is the continuation's first
    // real model call: it sees the summary AND the verbatim continuation
    // envelope (the unread opening stays outside the covered range), while
    // turn 1's content is gone.
    assert_true(request_bodies[1].contains("CONTEXT CHECKPOINT COMPACTION"))
    assert_true(request_bodies[2].contains("continuation checkpoint"))
    assert_true(request_bodies[2].contains("openseek_internal_context"))
    assert_false(request_bodies[2].contains("worked on it"))
    let goals = goal_events_of(result)
    assert_true(goals[goals.length() - 1].status() is Complete)
  }
}

///|
async test "summarizer spend that crosses the goal budget stops the turn" {
  @async.with_task_group() <| group => {
    let request_bodies : Array[String] = []
    let responses = [
      // Step 1: 160 tokens spent — under the 170 budget, over the
      // compaction threshold.
      [
        tool_call_chunk(
          "call_1", "read", "{\\\"path\\\":\\\"missing-budget-probe.txt\\\"}", 150,
          10,
        ),
      ],
      // The auto-compaction request: its 52 tokens push spend to 212,
      // past the budget. No third model call may happen.
      [content_chunk("checkpoint before the budget line", 40, 12)],
    ]
    guard goal_test_server(group, responses, request_bodies) is Some(url) else {
      return
    }
    let runtime = @agent_runtime.AgentRuntime()
    let scope = @agent_runtime.AgentTaskScope(group)
    let session = @agent_session.Session(
      SessionId("compact-budget"),
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
      objective="obj-budget",
      token_budget=170,
      max_steps=6,
      max_continuations=1,
      api_url=url,
      compact_threshold=100,
    )
    // Exactly two requests: the summary is durable, the budget gate re-ran
    // after the summarizer's usage, and the run ended BudgetLimited.
    assert_eq(request_bodies.length(), 2)
    let mut has_summary = false
    for event in result.events() {
      if event.item() is Summary(_) {
        has_summary = true
      }
    }
    assert_true(has_summary)
    let goals = goal_events_of(result)
    assert_true(goals[goals.length() - 1].status() is BudgetLimited)
  }
}
