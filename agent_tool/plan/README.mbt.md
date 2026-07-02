# Plan Tool

`plan` records or replaces the agent's step-by-step plan for the current task.
The model calls it with the complete ordered list of steps; the tool validates
the plan, echoes it back as a normalized checklist, and summarizes progress in
the `brief` line the UI displays.

## Design Rationale

The tool is deliberately **stateless**: every call passes the whole plan and
replaces the previous one, so plan state lives in the transcript itself. The
checklist in each tool result is re-read by the model on every request, which
keeps long multi-step runs anchored to the plan without any host-side state to
reconcile, persist, or leak across turns.

It exists because models externalize plans anyway — the multi-step evals
recorded a run that emitted a JSON plan as plain assistant text instead of
calling tools. A sanctioned plan channel turns that impulse into a tool call
that keeps the loop moving, and gives the UI a progress line for free.

Unlike `finish`, decoding is **strict**: a malformed plan comes back as an
error naming the first offending field (`arguments.steps[2].status ...`), so
the model can correct the call instead of silently recording a broken plan.

## API Style

Use `plan` at the start of a task that needs several distinct steps, then call
it again as statuses change (typically marking one step `done` and the next
`active`). Skip it for trivial single-step tasks. Statuses: `pending`,
`active` (at most one), `done`.

```json
{
  "steps": [
    { "title": "read the failing test", "status": "done" },
    { "title": "fix the parser", "status": "active" },
    { "title": "run moon test", "status": "pending" }
  ]
}
```

## Arguments

| Name    | Type  | Required | Notes |
| ------- | ----- | -------- | ----- |
| `steps` | array | yes | Complete ordered plan; replaces the previous plan. 1–20 items. Each item: non-blank string `title`, `status` in `pending`/`active`/`done`, at most one `active`. |

## Action

- `Respond(ToolOutput(...))` — the normalized checklist (`[x]` done, `[>]`
  active, `[ ]` pending) with a `Plan (n/m done)` header, and a brief like
  `plan 1/3 · fix the parser`.
- `Respond(is_error=true)` — malformed arguments; the message names the first
  offending field so the next call can fix it.

## Example

```moonbit check
///|
test "plan tool advertises the expected schema" {
  let tool = @plan.definition()
  assert_eq(tool.name, "plan")
  let JsonSchema(schema) = tool.schema
  let text = schema.stringify()
  assert_true(text.contains("\"steps\""))
  assert_true(text.contains("\"required\""))
}
```

```moonbit check
///|
async test "plan tool renders a checklist through the registry" {
  let tools = @agent_tool.Tools([@plan.definition()])
  let call = @agent_tool.AgentToolCall(
    ToolCall(
      id="call_plan",
      name="plan",
      arguments=(
        #|{
        #|  "steps": [
        #|    { "title": "outline the fix", "status": "done" },
        #|    { "title": "apply the edit", "status": "active" },
        #|    { "title": "run moon check", "status": "pending" }
        #|  ]
        #|}
      ),
    ),
  )
  let result = @agent_tool.execute_tool_call(call, tools)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("Plan (1/3 done)"))
  assert_true(output.content.contains("[>] apply the edit"))
}
```
