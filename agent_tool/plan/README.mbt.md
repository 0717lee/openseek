# Plan Tool

`plan` records or replaces the agent's step-by-step plan for the current task.
The model calls it with the complete ordered list of steps; the tool validates
the plan, acknowledges it tersely, and summarizes progress in the `brief` line
the UI displays.

## Design Rationale

The tool is deliberately **stateless**: every call passes the whole plan and
replaces the previous one, so plan state lives in the transcript itself. The
tool-call arguments are replayed to the model on every request, which keeps
long multi-step runs anchored to the plan without any host-side state to
reconcile, persist, or leak across turns. The result is a terse acknowledgment
rather than an echo of the plan — the arguments already carry it, and echoing
it again would double its context cost on every future request.

It exists because models externalize plans anyway — the multi-step evals
recorded a run that emitted a JSON plan as plain assistant text instead of
calling tools. A sanctioned plan channel turns that impulse into a tool call
that keeps the loop moving, and gives the UI a progress line for free.

Unlike `finish`, decoding is **strict**: a malformed plan comes back as an
error naming the first offending field (`arguments.steps[2].status ...`), so
the model can correct the call instead of silently recording a broken plan.
Unknown fields — on the arguments or on a step — are rejected, exactly as the
advertised schema's `additionalProperties: false` promises.

## API Style

Use `plan` at the start of a task that needs several distinct steps, then call
it again as statuses change (typically marking one step `completed` and the
next `in_progress`). Skip it for trivial single-step tasks. Pass `"steps": []`
to clear a plan that no longer applies. Statuses: `pending`, `in_progress`
(at most one), `completed`.

```json
{
  "steps": [
    { "title": "read the failing test", "status": "completed" },
    { "title": "fix the parser", "status": "in_progress" },
    { "title": "run moon test", "status": "pending" }
  ]
}
```

## Arguments

| Name    | Type  | Required | Notes |
| ------- | ----- | -------- | ----- |
| `steps` | array | yes | Complete ordered plan; replaces the previous plan, empty clears it. At most 20 items. Each item: single-line `title` (trimmed, non-blank, ≤120 characters), `status` in `pending`/`in_progress`/`completed`, at most one `in_progress`, no other fields. |

## Action

- `Respond(ToolOutput(...))` — a terse acknowledgment
  (`Plan updated: 1/3 done · in progress: fix the parser.`) and a brief like
  `plan 1/3 · fix the parser`. When every step is completed and none of them
  looks like a verification step, the acknowledgment appends a reminder to
  verify before finishing.
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
async test "plan tool acknowledges progress through the registry" {
  let tools = @agent_tool.Tools([@plan.definition()])
  let call = @agent_tool.AgentToolCall(
    ToolCall(
      id="call_plan",
      name="plan",
      arguments=(
        #|{
        #|  "steps": [
        #|    { "title": "outline the fix", "status": "completed" },
        #|    { "title": "apply the edit", "status": "in_progress" },
        #|    { "title": "run moon check", "status": "pending" }
        #|  ]
        #|}
      ),
    ),
  )
  let result = @agent_tool.execute_tool_call(call, tools)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(
    output.content.contains(
      "Plan updated: 1/3 done · in progress: apply the edit.",
    ),
  )
  guard output.brief is Some(brief) else { fail("expected a brief") }
  assert_eq(brief, "plan 1/3 · apply the edit")
}
```
