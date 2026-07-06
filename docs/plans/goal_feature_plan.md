# Goal Feature Plan for OpenSeek (v2)

Status: v2 — revised after two codex CLI review sessions:
(1) a critique of v1 against the actual Codex implementation and the OpenSeek
codebase, and (2) a whole-system analysis of `/plan` (PR #344) + `/goal`.
Reference implementation: `.repos/codex` (`codex-rs/ext/goal/`,
`ThreadGoal` in `codex-rs/protocol/src/protocol.rs`, `/goal` TUI files).

## What Codex's `/goal` actually is

1. **Durable per-thread state** (`ThreadGoal`): `objective` (≤ 4,000 chars),
   `status` (Active/Paused/Blocked/UsageLimited/BudgetLimited/Complete),
   optional `token_budget`, `tokens_used`, `time_used_seconds`, timestamps.
   Survives resume (`GoalRuntimeHandle::restore_after_resume`).
2. **Model-facing tools** (`ext/goal/src/spec.rs`): `get_goal`, `create_goal`
   (only on explicit user request; fails if an unfinished goal exists),
   `update_goal` (status only). Descriptions encode strict audit rules.
   NOTE (review 1): `update_goal` is a *normal responding tool* in Codex —
   it updates state and returns a structured response; the turn still ends
   through normal completion (`ext/goal/src/tool.rs:221`). It is not loop
   control.
3. **Steering injection** (`ext/goal/src/steering.rs` + `templates/goals/`):
   *hidden* internal-context fragments (`<codex_internal_context
   source="goal">`) rendered from `continuation.md` (objective + budget +
   anti-scope-narrowing + evidence-based completion audit + "blocked only
   after 3 consecutive blocked turns"), `objective_updated.md`, and
   `budget_limit.md`.
4. **Auto-continuation runtime** (`ext/goal/src/runtime.rs`): when the thread
   goes idle with an Active goal, the runtime injects the continuation item
   and starts a new turn itself. Stops on Complete/Blocked/budget/user pause.
5. **Accounting** (`ext/goal/src/accounting.rs`): per-turn token usage
   recorded against the goal; budget exhaustion flips status and injects the
   budget-limit steering item.

## Corrections from review 1 (facts about OpenSeek v1 got wrong)

- **Usage is not persisted.** Token usage is only process-logged
  (`agent/agent.mbt:575` `print_usage`), never stored in `agent_session`.
  Budget accounting therefore needs a new persisted `Usage` event first.
- **Steering is not a continuation vehicle.** Steers are drained only inside
  an active turn (`agent/agent.mbt:555`) and serve mode drops idle steers
  (`cmd/openseek/serve.mbt:400`). Continuation requires a scheduler that
  starts new turns, not a queued steer.
- **No hidden model-context channel exists.** `User`, `Runtime`, and
  `Summary` all project into visible model messages
  (`agent_session/projection.mbt:41`). Repeated goal continuations as
  ordinary `User` events would pollute the transcript and replay context.
- **Tool executors are `Json -> ToolAction` only** (`agent_tool/agent_tool.mbt:62`);
  `scope` is plumbed but ignored (`agent/tool_definition.mbt:10`). Goal tools
  need a real execution context able to read a session snapshot and append
  goal events atomically — a new mechanism, not just a closure handle.
- **TUI/serve lifecycle**: the client flips `run_open=false` on terminal
  events (`cmd/tui/engine_client.mbt:105`) and the UI calls `finish_run` on
  `AgentFinished` (`cmd/tui/loop.mbt:452`). Auto-continuation needs new
  goal-running events or the UI shows idle between automatic turns.

## Resolved design decisions (from both reviews)

1. **Goal state = session events, metadata-only.** New event kinds are
   appended to the session log (the existing resume boundary) but are
   *skipped by `chat_messages` projection* — they are host state, not
   conversation. Include `goal_id`, timestamps, `tokens_used`.
2. **Build the hidden internal-context channel first.** A new projection path
   for internal model context (Codex's `InternalModelContextFragment`
   equivalent) so continuation prompts reach the model without becoming
   permanent visible user messages.
3. **Keep `finish`; reword it.** `finish` stays registered (suppressing it
   risks trapping the model) but its description becomes turn-scoped when a
   goal is active ("end this turn"), not "end the task".
4. **`update_goal` is a responding tool**, never `Control(Finish)`. The turn
   ends normally; the goal loop reads the new status afterwards.
5. **Budget truth = fold of persisted events.** A mutable cache is a
   permissible optimization; the durable log must replay to the same state
   after resume.
6. **Port Codex's audit prose nearly intact** (fidelity, completion audit,
   blocked audit). Reference the `plan` tool conditionally — only if PR #344
   has landed.
7. **Anti-runaway is mandatory in v1**: a host-level token budget (even when
   the user sets none) plus a continuation cap. Unattended auto-continuation
   without durable accounting is too easy to burn through.

## `/plan` + `/goal` as one system (review 2)

- **Separation of concerns**: goal = durable destination owned by the host;
  plan = model-managed route living only in the transcript. No host-side
  coupling between them, ever.
- **Continuation references the plan; it does not echo it.** The continuation
  prompt says: use the latest visible plan tool result if still aligned;
  update or replace it when stale; ignore it when it conflicts with the goal
  or worktree evidence. `plan` stays stateless.
- **Plan lifecycle across continuations is model-managed.** No reset per
  continuation (churn), no host persistence (stale-plan reconciliation).
- **Status vocabularies stay disjoint.** Plan steps:
  `pending`/`in_progress`/`completed` (step-local bookkeeping). Goal:
  `Active`/`Complete`/`Blocked`/`BudgetLimited` (lifecycle gates). No
  `blocked` plan status. (PR #344 was amended accordingly: statuses renamed,
  the all-done brief avoids the word "complete".)
- **A fully completed plan is not completion evidence.** The continuation
  prompt states this explicitly; only the evidence-based completion audit
  justifies `update_goal("complete")`. (Also now stated in the plan tool's
  own description.)

## Revised phasing

### Phase 0 — Substrate (new; was missing in v1)
- Persisted `Usage` event in `agent_session` (per-response prompt/completion
  tokens), emitted by the loop alongside the existing log line.
- Metadata-only event support: session items that store/replay but do not
  project into `chat_messages`.
- Internal model-context projection path: a session item that projects into a
  model message wrapped in an internal-context envelope, which the TUI can
  render distinctly (or fold away) instead of showing as a user message.
- Tests: projection skip/include, store round-trip, resume equivalence.

### Phase 1 — Goal state
- `GoalUpdate { goal_id, objective, status, token_budget?, tokens_used,
  created_at, updated_at }`, `GoalStatus = Active | Complete | Blocked |
  BudgetLimited`; `Session::current_goal()` = fold of goal events.
- Objective cap 4,000 chars (mirror `MAX_THREAD_GOAL_OBJECTIVE_CHARS`).

### Phase 2 — Goal tools
- A tool execution context (the real work): executors gain access to a
  session snapshot + atomic append of goal events. Design this as a small
  capability record threaded through `build_tools`, replacing the ignored
  `scope` plumbing.
- `create_goal(objective, token_budget?)` — explicit-request-only wording;
  fails if an unfinished goal exists. `update_goal(status)` —
  complete|blocked, responding tool, audit rules in the description.
  `get_goal()` — objective, status, tokens used/remaining.
- Deterministic harness cases for all three.

### Phase 3 — Continuation loop
- Goal-aware run wrapper in `agent`: after a turn terminates, fold goal +
  usage events; if Active and budget remains, render the continuation
  template (`prompt/goal_continuation.mbt.md`, ported from Codex incl.
  completion/blocked audits and the plan-reference paragraph) as an internal
  context item and start the next turn from the scheduler (not via steer).
- Stop conditions: Complete/Blocked, budget exhausted (append
  `BudgetLimited` + budget-limit notice once), continuation cap (default 25),
  user interrupt.
- Tests: budget stop, `finish`-continues-active-goal, `update_goal` stops
  only after the turn's final answer, resume mid-goal continues correctly.

### Phase 4 — Surfaces (deliberately last; cut from v1 if needed)
- CLI: `openseek run --goal "..."` (+ budget flag).
- Serve/TUI: new goal-running lifecycle events so the UI doesn't show idle
  between automatic turns; goal status line. TUI `/goal` editing can wait.
- Docs + one long-horizon eval case (single-turn fails, goal loop succeeds).

## Deferred (explicitly out of v1)
Paused/UsageLimited statuses, time accounting, attachment materialization
(oversized objectives → files), TUI goal editing, multi-thread routing.
