///|
fn goal_set_notice(text : String) -> @agent_session.SessionItem {
  Runtime(RuntimeNotice("\{@agent_session.GoalPrefix}\n\{text}"))
}

///|
test "current_goal is none without markers" {
  let session = @agent_session.Session(SessionId("s1"), system_prompt="system")
    .append(User(UserMessage("hello")))
    .append(
      Runtime(RuntimeNotice("\{@agent_session.PlanReminderPrefix}\nplan")),
    )
  assert_true(session.current_goal() is None)
}

///|
test "current_goal returns the last set marker" {
  let session = @agent_session.Session(SessionId("s1"), system_prompt="system")
    .append(goal_set_notice("port the decoder"))
    .append(User(UserMessage("start with the parser")))
  guard session.current_goal() is Some(goal) else { fail("expected a goal") }
  assert_eq(goal.text(), "port the decoder")
  assert_false(goal.answered_since_set())
}

///|
test "current_goal marks goals the model has answered since" {
  let assistant_first = @agent_session.Session(
      SessionId("s1"),
      system_prompt="system",
    )
    .append(goal_set_notice("port the decoder"))
    .append(Assistant(AssistantMessage("on it")))
  guard assistant_first.current_goal() is Some(goal) else {
    fail("expected a goal")
  }
  assert_true(goal.answered_since_set())
  let terminal_only = @agent_session.Session(
      SessionId("s2"),
      system_prompt="system",
    )
    .append(goal_set_notice("port the decoder"))
    .append(Terminal(Finished("done for now")))
  guard terminal_only.current_goal() is Some(goal) else {
    fail("expected a goal")
  }
  assert_true(goal.answered_since_set())
}

///|
test "cleared tombstone hides earlier goals and a later set revives" {
  let cleared = @agent_session.Session(SessionId("s1"), system_prompt="system")
    .append(goal_set_notice("first objective"))
    .append(Runtime(RuntimeNotice(@agent_session.GoalClearedNotice)))
  assert_true(cleared.current_goal() is None)
  let revived = cleared.append(goal_set_notice("second objective"))
  guard revived.current_goal() is Some(goal) else { fail("expected a goal") }
  assert_eq(goal.text(), "second objective")
}

///|
test "reminder and check notices are not set markers" {
  let session = @agent_session.Session(SessionId("s1"), system_prompt="system")
    .append(goal_set_notice("real goal"))
    .append(Runtime(RuntimeNotice(@agent_session.GoalClearedNotice)))
    .append(
      Runtime(
        RuntimeNotice("\{@agent_session.GoalReminderPrefix}\nstale reminder"),
      ),
    )
    .append(
      Runtime(RuntimeNotice("\{@agent_session.GoalCheckPrefix}\nstale check")),
    )
  // The cleared tombstone stays authoritative: reminder/check tags after it
  // must not resurrect the goal.
  assert_true(session.current_goal() is None)
}

///|
test "multiline goal text survives the scan" {
  let session = @agent_session.Session(SessionId("s1"), system_prompt="system").append(
    goal_set_notice("line one\nline two"),
  )
  guard session.current_goal() is Some(goal) else { fail("expected a goal") }
  assert_eq(goal.text(), "line one\nline two")
}

///|
test "a compaction summary covering the set marker does not hide the goal" {
  let session = @agent_session.Session(SessionId("s1"), system_prompt="system")
    .append(goal_set_notice("long objective"))
    .append(User(UserMessage("work on it")))
    .append(Assistant(AssistantMessage("progress")))
    .compact(content="summary of the work", from_sequence=1, to_sequence=3)
  guard session.current_goal() is Some(goal) else { fail("expected a goal") }
  assert_eq(goal.text(), "long objective")
  assert_true(goal.answered_since_set())
}
