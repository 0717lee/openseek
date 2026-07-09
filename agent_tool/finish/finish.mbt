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
pub fn definition() -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="finish",
    description="End the task with arguments.answer.",
    schema=JsonSchema({
      "type": "object",
      "properties": { "answer": { "type": "string" } },
      "required": ["answer"],
    }),
    execute=Sync(execute),
    control=true,
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
