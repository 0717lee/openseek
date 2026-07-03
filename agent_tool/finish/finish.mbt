///|
/// Tool definition for `finish`: ends the agent loop with `arguments.answer`
/// as the final response surfaced to the user.
///
/// ## Arguments
/// - `answer` (string, required): the final answer text.
///
/// ## Result
/// - `Control(Finish(<answer>))` — stops the loop and returns the string.
///   Missing or non-string `answer` produces `Control(Finish(""))`.
///
/// `finish` is the only built-in tool whose action is not `Respond`. The loop
/// always stops after `finish` runs, regardless of what comes back.
pub fn definition(
  turn_scoped? : Bool = false,
) -> @agent_tool.AgentToolDefinition {
  // Under a goal, `finish` ends only the current turn: the goal loop keeps
  // starting turns while the goal stays active, and only update_goal (or
  // the host's budget/cap stops) ends the run. The description must say so —
  // tool descriptions are strong model-facing guidance, and "End the task"
  // would contradict the continuation prompt.
  let description = if turn_scoped {
    "End this turn with arguments.answer. While a goal is active this does not end the goal: the loop starts another goal turn; only update_goal finishes the run."
  } else {
    "End the task with arguments.answer."
  }
  AgentToolDefinition(
    name="finish",
    description~,
    schema=JsonSchema({
      "type": "object",
      "properties": { "answer": { "type": "string" } },
      "required": ["answer"],
    }),
    execute=Sync(execute),
  )
}

///|
fn execute(arguments : Json) -> @agent_tool.ToolAction {
  finish(@decode.decode(arguments))
}

///|
fn finish(input : @decode.FinishInput) -> @agent_tool.ToolAction {
  @agent_tool.ToolAction::finish(input.answer)
}

///|
/// Asserts that `execute(arguments)` yields `Control(Finish(expected))`.
fn assert_finish(arguments : Json, expected : String) -> Unit raise {
  guard execute(arguments) is Control(Finish(answer)) else {
    fail("expected Finish")
  }
  assert_eq(answer, expected)
}

///|
test "finish returns Finish with the answer" {
  assert_finish({ "answer": "all done" }, "all done")
}

///|
test "finish preserves multiline answers" {
  assert_finish({ "answer": "line one\nline two" }, "line one\nline two")
}

///|
test "finish ignores extra fields on the payload" {
  assert_finish({ "answer": "done", "extra": "ignored" }, "done")
}

///|
test "finish returns empty Finish when answer is missing" {
  assert_finish({}, "")
}

///|
test "finish returns empty Finish when answer is non-string" {
  assert_finish({ "answer": 42 }, "")
}

///|
test "finish returns empty Finish on non-object arguments" {
  assert_finish(Json::null(), "")
}
