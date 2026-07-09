# `goal` — the structured goal-status tool

The `goal` tool is how the model reports where the **standing session goal**
stands, as data instead of prose. It exists so the engine can stop, chain, or
keep working on a durable signal — never on parsing the model's phrasing.

## Arguments

- `status` (string, required): `"met"` or `"continuing"`.
- `remaining` (string, required when `status` is `"continuing"`): what is
  still left to do — must be non-blank, because this text is the durable
  record whoever (or whatever turn) resumes the goal will read.

## Result

This package only **decodes**; the action is the agent loop's. The loop
intercepts a `goal` call instead of dispatching it like an ordinary tool:

- `goal(met)` — the standing goal stops standing immediately (the finish
  check disarms) and a durable `[goal cleared]` tombstone lands at the next
  batch-safe boundary. Under auto-continue this is the **structural stop**:
  the chain ends on the tombstone, not on trusting an answer's wording.
- `goal(continuing)` — answers exactly what the finish check asks, so the
  check disarms for the rest of the turn and the turn may end with the goal
  still standing; `remaining` is recorded for the next turn.
- Invalid arguments come back as an error tool result naming the exact
  problem, so the model can re-issue the call without guessing.

The tool is registered only while a goal stands; `GoalCadence` selects the
tool-aware finish-check wording when it is (see `agent/goal.mbt`).

## Example

```moonbit check
///|
test "goal arguments decode to structured verdicts" {
  assert_true(@goal.decode_status({ "status": "met" }) is Ok(Met))
  assert_true(
    @goal.decode_status({ "status": "continuing", "remaining": "wire the CLI" })
    is Ok(Continuing("wire the CLI")),
  )
  // A blank `remaining` is rejected: the durable record must be actionable.
  assert_true(
    @goal.decode_status({ "status": "continuing", "remaining": "  " }) is Err(_),
  )
}
```
