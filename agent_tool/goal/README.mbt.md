# Goal Tools

`create_goal`, `update_goal`, and `get_goal` — the model-facing surface of
the goal feature (see `docs/plans/goal_feature_plan.md`), mirroring Codex's
goal tool spec. A goal is a durable objective that keeps the agent working
across turns: the loop in `agent/goal_loop.mbt` re-injects a continuation
prompt while the goal stays active, and only `update_goal` (or the host's
budget/cap stops) ends the run.

## Design Rationale

Tool executors are pure `Json -> ToolAction` functions, so goal tools cannot
append session events themselves. All three tools share one per-run
`GoalCell` with the agent loop:

- tools record requested transitions in the cell (`create_goal`,
  `update_goal`) and answer reads from it (`get_goal`);
- the loop drains pending transitions into durable `Goal` session events
  right after each tool result and re-points the cell at the updated fold,
  so the cell always agrees with the log and every durable append stays on
  one code path;
- goal ids allocate as `goal-<prior goal events + 1>`, which never reuses an
  earlier instance's id — the accounting fold in
  `agent_session/goal.mbt` depends on that guarantee;
- `refresh` drops undrained transitions: if a turn dies between a tool
  response and the drain, the durable log wins.

Guardrails carried in the tool descriptions (ported from Codex):
`create_goal` is explicit-user-request-only and refuses to replace an
unfinished goal (Active or BudgetLimited — a spent budget is not a met
objective); `update_goal` reaches only `complete` (after an evidence-based
completion audit) or `blocked` (only after the same impasse repeats for
three consecutive goal turns).

## Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `create_goal` | `objective` (≤ 4000 chars), `token_budget?` (positive) | starts an Active goal; error while an unfinished goal exists |
| `update_goal` | `status`: `complete` \| `blocked` | transitions the active goal; the turn still ends normally |
| `get_goal` | — | objective, status, budget, tokens used/remaining |

## Example

```moonbit check
///|
test "goal tools share one cell" {
  let cell = @goal.GoalCell()
  let tools = @agent_tool.Tools(@goal.definitions(cell))
  guard tools.find("create_goal") is Some(create) else { fail("create_goal") }
  guard create.execute is Sync(create_execute) else { fail("Sync") }
  let created = create_execute({ "objective": "keep the build green" })
  guard created is Respond(output) else { fail("Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("goal goal-1 created"))
  // The transition waits for the loop to drain it into a durable event.
  assert_eq(cell.drain_pending().length(), 1)
}
```
