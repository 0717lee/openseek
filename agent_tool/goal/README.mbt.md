# Goal Tool

`goal` reports a structured verdict about the standing session goal. The
agent loop uses that verdict to decide whether to stop autonomous work,
continue it in another turn, or pause for the user. It never has to infer goal
state from prose in the assistant response.

The tool is registered only while a goal stands. Calling it without a standing
goal is a semantic error handled by the agent loop.

## Arguments

| `status` | Required companion field | Meaning |
| --- | --- | --- |
| `"met"` | none | The goal is fully achieved and verified. |
| `"continuing"` | `remaining` (non-blank string) | Work remains and can continue autonomously. |
| `"blocked"` | `reason` (non-blank string) | Progress requires user action or an external-state change. |

`blocked` is for a genuine impasse, not a failed command or another recoverable
problem. A later `continuing` verdict resumes a blocked goal.

The JSON schema declares unknown fields invalid. Conditional requirements for
`remaining` and `reason` are enforced by the decoder in
`agent_tool/goal/internal/decode`.

## Lifecycle Effects

- `met` clears the standing goal. The loop writes a durable `[goal cleared]`
  marker at the next batch-safe boundary; under auto-continuation, that marker
  is the structural stop signal.
- `continuing` records the actionable remainder and satisfies the finish check
  for the current turn. The goal remains standing. If it was blocked, the loop
  also records `[goal unblocked]` and resumes auto-continuation.
- `blocked` records why work cannot proceed and writes `[goal blocked]`. The
  goal remains standing for the user, but auto-continuation pauses.

The agent loop intercepts `goal` calls because it owns the standing state and
durable log. The definition's executor is only a stateless fallback for direct
registry dispatch: it validates the arguments and responds without changing
goal state.

## Schema

This checked example doubles as a readable snapshot of the tool's public JSON
contract:

```mbt check
///|
test "goal tool schema" {
  let tool = @goal.definition()
  assert_eq(tool.name, "goal")
  assert_true(tool.control)
  json_inspect(tool.schema.0, content={
    "type": "object",
    "properties": {
      "status": { "type": "string", "enum": ["met", "continuing", "blocked"] },
      "remaining": {
        "type": "string",
        "description": "Required when status is \"continuing\": one or two lines on what is left to reach the goal.",
      },
      "reason": {
        "type": "string",
        "description": "Why the goal cannot proceed; required with status \"blocked\".",
      },
    },
    "required": ["status"],
    "additionalProperties": false,
  })
}
```
