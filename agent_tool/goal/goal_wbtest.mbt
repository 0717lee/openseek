///|
fn dispatch(
  cell : GoalCell,
  name : String,
  arguments : Json,
) -> @agent_tool.ToolAction raise {
  for definition in definitions(cell) {
    if definition.name == name {
      guard definition.execute is Sync(execute) else { fail("expected Sync") }
      return execute(arguments)
    }
  }
  fail("unknown tool \{name}")
}

///|
fn expect_respond(
  action : @agent_tool.ToolAction,
  is_error~ : Bool,
) -> String raise {
  guard action is Respond(output) else { fail("expected Respond") }
  assert_eq(output.is_error, is_error)
  output.content
}

///|
test "create_goal starts an active goal and rejects a second one" {
  let cell = GoalCell()
  let created = expect_respond(
    dispatch(cell, "create_goal", { "objective": "ship the feature" }),
    is_error=false,
  )
  assert_true(created.contains("goal goal-1 created"))
  assert_true(created.contains("status: active, no token budget"))
  guard cell.current() is Some(goal) else { fail("expected goal") }
  assert_true(goal.status() is Active)
  let rejected = expect_respond(
    dispatch(cell, "create_goal", { "objective": "another" }),
    is_error=true,
  )
  assert_true(rejected.contains("an unfinished goal exists (goal-1)"))
}

///|
test "create_goal validates arguments and budget" {
  let cell = GoalCell()
  let missing = expect_respond(dispatch(cell, "create_goal", {}), is_error=true)
  assert_true(missing.contains("arguments.objective to be a string"))
  let blank = expect_respond(
    dispatch(cell, "create_goal", { "objective": "  " }),
    is_error=true,
  )
  assert_true(blank.contains("arguments.objective to be non-blank"))
  let bad_budget = expect_respond(
    dispatch(cell, "create_goal", { "objective": "x", "token_budget": 0 }),
    is_error=true,
  )
  assert_true(bad_budget.contains("token_budget to be a positive integer"))
  let with_budget = expect_respond(
    dispatch(cell, "create_goal", { "objective": "x", "token_budget": 500 }),
    is_error=false,
  )
  assert_true(with_budget.contains("token budget 500"))
}

///|
test "create_goal allocates non-colliding ids from seen events" {
  // Two prior goal events (creation + completion of goal-1): the next id
  // must skip past every earlier event.
  let cell = GoalCell(goal_events_seen=2)
  let created = expect_respond(
    dispatch(cell, "create_goal", { "objective": "next objective" }),
    is_error=false,
  )
  assert_true(created.contains("goal goal-3 created"))
}

///|
test "update_goal transitions the active goal and drains in order" {
  let cell = GoalCell()
  let _ = dispatch(cell, "create_goal", { "objective": "ship it" })
  let done = expect_respond(
    dispatch(cell, "update_goal", { "status": "complete" }),
    is_error=false,
  )
  assert_true(done.contains("goal goal-1 marked complete"))
  let drained = cell.drain_pending()
  assert_eq(drained.length(), 2)
  assert_true(drained[0].status() is Active)
  assert_true(drained[1].status() is Complete)
  assert_eq(drained[1].goal_id(), "goal-1")
  assert_eq(cell.drain_pending().length(), 0)
}

///|
test "update_goal guards missing, finished, and malformed input" {
  let cell = GoalCell()
  let none = expect_respond(
    dispatch(cell, "update_goal", { "status": "complete" }),
    is_error=true,
  )
  assert_true(none.contains("no goal is set"))
  let _ = dispatch(cell, "create_goal", { "objective": "ship it" })
  let bad = expect_respond(
    dispatch(cell, "update_goal", { "status": "paused" }),
    is_error=true,
  )
  assert_true(bad.contains("to be one of complete|blocked"))
  let _ = dispatch(cell, "update_goal", { "status": "blocked" })
  let again = expect_respond(
    dispatch(cell, "update_goal", { "status": "complete" }),
    is_error=true,
  )
  assert_true(again.contains("is already blocked"))
}

///|
test "get_goal reports state and budget arithmetic" {
  let cell = GoalCell()
  let empty = expect_respond(dispatch(cell, "get_goal", {}), is_error=false)
  assert_eq(empty, "no goal is set")
  let _ = dispatch(cell, "create_goal", {
    "objective": "ship it",
    "token_budget": 100,
  })
  cell.refresh(cell.current(), tokens_used=30, goal_events_seen=1)
  let report = expect_respond(dispatch(cell, "get_goal", {}), is_error=false)
  assert_true(report.contains("status: active"))
  assert_true(
    report.contains("tokens used: 30 · budget: 100 · remaining: 70"),
  )
  assert_true(report.contains("<objective>\nship it\n</objective>"))
}

///|
test "create_goal refuses to replace a budget-limited goal" {
  let cell = GoalCell()
  let _ = dispatch(cell, "create_goal", {
    "objective": "ship it",
    "token_budget": 10,
  })
  guard cell.current() is Some(goal) else { fail("expected goal") }
  // The host marks the goal budget-limited (phase 3); simulate that view.
  let limited = @agent_session.GoalUpdate(
    goal_id=goal.goal_id(),
    objective=goal.objective(),
    status=BudgetLimited,
    token_budget=10,
  )
  cell.refresh(Some(limited), tokens_used=10, goal_events_seen=2)
  let rejected = expect_respond(
    dispatch(cell, "create_goal", { "objective": "replacement" }),
    is_error=true,
  )
  assert_true(rejected.contains("an unfinished goal exists"))
}

///|
test "refresh drops stale pending transitions" {
  let cell = GoalCell()
  let _ = dispatch(cell, "create_goal", { "objective": "ship it" })
  assert_eq(cell.drain_pending().length(), 1)
  let _ = dispatch(cell, "update_goal", { "status": "complete" })
  // The turn dies before the loop drains; a later refresh re-points the
  // cell at the durable fold and must discard the undrained transition.
  cell.refresh(None, tokens_used=0, goal_events_seen=0)
  assert_eq(cell.drain_pending().length(), 0)
}

///|
test "update_goal can close a budget-limited goal" {
  // BudgetLimited must stay closable, or no tool path out of it exists and
  // goal creation deadlocks (phase 3 review, finding 1).
  let cell = GoalCell()
  let _ = dispatch(cell, "create_goal", {
    "objective": "ship it",
    "token_budget": 10,
  })
  guard cell.current() is Some(goal) else { fail("expected goal") }
  let limited = @agent_session.GoalUpdate(
    goal_id=goal.goal_id(),
    objective=goal.objective(),
    status=BudgetLimited,
    token_budget=10,
  )
  cell.refresh(Some(limited), tokens_used=10, goal_events_seen=2)
  let closed = expect_respond(
    dispatch(cell, "update_goal", { "status": "blocked" }),
    is_error=false,
  )
  assert_true(closed.contains("marked blocked"))
}

///|
test "create_goal is rejected in automatic goal turns" {
  // Goals answer explicit user requests; a continuation turn has none, and
  // allowing creation there would let blocked-then-create keep the loop
  // running past the user boundary (phase 3 review, finding 2).
  let cell = GoalCell()
  cell.allow_creation(false)
  let rejected = expect_respond(
    dispatch(cell, "create_goal", { "objective": "sneaky new goal" }),
    is_error=true,
  )
  assert_true(rejected.contains("user turns only"))
  cell.allow_creation(true)
  let created = expect_respond(
    dispatch(cell, "create_goal", { "objective": "legit goal" }),
    is_error=false,
  )
  assert_true(created.contains("goal goal-1 created"))
}

///|
test "budget_exhausted reflects the refreshed view" {
  let cell = GoalCell()
  assert_false(cell.budget_exhausted())
  let _ = dispatch(cell, "create_goal", {
    "objective": "ship it",
    "token_budget": 10,
  })
  cell.refresh(cell.current(), tokens_used=9, goal_events_seen=1)
  assert_false(cell.budget_exhausted())
  cell.refresh(cell.current(), tokens_used=10, goal_events_seen=1)
  assert_true(cell.budget_exhausted())
}
