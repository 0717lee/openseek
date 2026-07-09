///|
test "a new goal observed after met drops the stale tombstone" {
  let session = @agent_session.Session(SessionId("s1"), system_prompt="system").append(
    Runtime(RuntimeNotice("\{@agent_session.GoalPrefix}\nold objective")),
  )
  let cadence = GoalCadence(session, tool_registered=true)
  cadence.record_goal_met()
  assert_true(cadence.pending_tombstone)
  // A steered-in set supersedes the met verdict: flushing the old
  // tombstone after the new marker would wipe the new goal.
  cadence.observe_notice("\{@agent_session.GoalPrefix}\nnew objective")
  assert_false(cadence.pending_tombstone)
  assert_true(cadence.goal is Some("new objective"))
  // A durable clear also settles a pending tombstone.
  cadence.record_goal_met() |> ignore
  cadence.observe_notice(@agent_session.GoalClearedNotice)
  assert_false(cadence.pending_tombstone)
  assert_true(cadence.goal is None)
}

///|
test "a goal set after an earlier check re-arms the finish check" {
  let session = @agent_session.Session(
    SessionId("goal-recheck"),
    system_prompt="sys",
  )
  let cadence = GoalCadence(session, tool_registered=false)
  cadence.observe_notice("\{@agent_session.GoalPrefix}\nfirst objective")
  cadence.record_finish_check()
  assert_true(cadence.due_finish_check() is None)
  // A NEW goal deserves its own check — the earlier one confirmed a
  // different objective.
  cadence.observe_notice("\{@agent_session.GoalPrefix}\nsecond objective")
  assert_true(cadence.due_finish_check() is Some("second objective"))
}
