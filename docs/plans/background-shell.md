# Background shell commands (Claude Code parity)

## Goal

Foreground-by-default shell, but with Claude Code's escape hatches:
- explicit `run_in_background` on `shell`,
- **detach-on-timeout** instead of hard-kill,
- `shell_output` / `shell_stop` to poll and terminate,
- **push-completion** via the steer queue,
- structured-concurrency "no orphans" guarantee lifted from call-scope to session-scope.

## Grounding in the current code

- `agent_tool/shell/shell.mbt` runs each command in a **per-call** `@async.with_task_group` and `hard_cancel`s on `timeout_ms` — the process cannot outlive the call, and the shell parser bans `&`.
- `agent_tool/moon_check` is the template: a `MoonCheckRuntime[X]` holds `scope : AgentTaskScope[X]` + a registry `Map[.., MoonCheckRecord]`, spawns on `scope.group()` with a `spawn_bg` monitor task draining the pipe, and reaps on session-scope teardown. `Process::cancel()` stops one process.
- Push channel: `AgentRuntime.queue_steer()` / `drain_steers()`; the loop drains at each step boundary and `apply_steer_inputs` folds each into the conversation (`agent/agent.mbt:293-322`).

## Delivery — two PRs, small reviewable commits

Every commit gate: `moon fmt` → `moon check --target native <pkgs>` → `moon test <pkgs>` → `codex review --base <prev-commit-sha>` (run in background, read the verdict tail, fix real findings, re-review clean) → drive the real tool where a surface exists.

### PR A — explicit background (`run_in_background` + poll/stop)

- **A1** — `agent_tool/bgjobs`: `BgJobRuntime[X]` (scope + registry + id counter), generic over `program`/`args`. `start`, `snapshot`, `list`, `stop`. Tail-capped output buffer, status `Running | Exited(code) | Stopped`. Pure infra, unwired.
- **A2** — `run_in_background` param on `shell`; thread a shared `BgJobRuntime` into `shell.definition(...)` (mirror `moon_check(runtime, scope)`); `true` → `start` a job via the platform shell and return the job id; `false` unchanged. Register in the standard tool set.
- **A3** — `agent_tool/shell_output` tool: poll a job's output + status by id.
- **A4** — `agent_tool/shell_stop` tool + explicit session-teardown reap; confirm no orphans.

### PR B — parity (auto-detach + push)

- **B1** — push-completion: on job exit, `queue_steer(<notice>)`; extend `SteerInput` with a notice kind if needed; loop injects "background job `<id>` finished (exit N)".
- **B2** — detach-on-timeout: on `timeout_ms`, hand the still-running process to the registry and return "moved to background as `<id>`" instead of `hard_cancel`. Spawn the auto-bg path on the **session** group; ship **opt-in** first, flip default later.
- **B3** — prompt/description update (mention `run_in_background` + the two tools) + runaway-output size watchdog.

## Test plan

Principles (apply to every commit):
- **Native target** — async process spawning needs `moon test --target native`.
- **Deterministic polling** — never unbounded wait; poll `snapshot` with bounded ticks + `@async.sleep`, and `fail(...)` on a deadline (mirror `wait_for_initial_snapshot`). Use commands that terminate fast (`printf`, `exit N`), and a real sleeper only for stop/timeout tests.
- **Isolation** — async tests run in parallel; each test uses its own temp/vfs cwd, no shared ports/files.
- **Regression** — the full `agent_tool/shell` suite stays green at every commit; the foreground path is untouched until B2, and then only behind the opt-in flag.

Per commit:

- **A1 (bgjobs)** — white-box `_wbtest.mbt`:
  - `sh -c 'printf hi'` → poll to `Exited(0)`, output contains `hi`.
  - `sh -c 'exit 3'` → `Exited(3)`.
  - `sh -c 'sleep 5'` → snapshot `Running`; `stop` → `Stopped`, terminates promptly (scope teardown does not hang).
  - output cap: high-volume command with tiny `max_output_chars` → `output_truncated`, output ≤ cap.
  - unknown id → `snapshot` None, `stop` false.
  - two concurrent jobs → distinct ids, independent output.
- **A2 (`run_in_background`)** — mirror `shell_test.mbt`'s `run_shell`:
  - `run_in_background:true` → response carries a job id, returns fast, `is_error=false`; the job appears in the runtime and later exits.
  - `false` → byte-identical to today (existing shell tests unchanged).
  - read-only/command-policy still enforced **before** spawning a background job.
- **A3 (`shell_output`)** — start a job → poll returns output + status; after exit → `Exited`; growing output advances `seq`; unknown id → `is_error` with a clear message.
- **A4 (`shell_stop`) + teardown** — start a sleeper → `stop` → `Stopped`, process gone; unknown id → `is_error`; ending the owning scope with a running job fires its `exited` signal (no-orphans).
- **B1 (push)** — a job exit enqueues a `SteerInput`; `drain_steers()` yields a completion notice with id + exit code; an integration test (mirror `plan_reminder_test`) asserts it becomes a durable injected item.
- **B2 (detach-on-timeout)** — command that outlives a small `timeout_ms` with auto-bg on → result says "moved to background as `<id>>`", job continues then exits, pre-timeout output preserved; auto-bg off → current timeout-error/kill behavior unchanged.
- **B3 (docs/watchdog)** — unbounded-output job is capped/killed; description strings contain `run_in_background` + `shell_output`/`shell_stop`.
