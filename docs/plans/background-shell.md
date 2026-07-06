# Background shell commands (Claude Code parity)

## Goal

Foreground-by-default shell, but with Claude Code's escape hatches:
- explicit `run_in_background` on `shell`,
- **detach-on-timeout** instead of hard-kill,
- `shell_output` / `shell_stop` to poll and terminate,
- **push-completion** when a job finishes,
- structured-concurrency "no orphans" guarantee lifted from call-scope to session-scope.

## The architecture to match (Claude Code)

Reverse-engineered from `.repos/claude-code-rev/src/utils/ShellCommand.ts`. The
whole design turns on **one idea: a command has a single execution and a single
output sink; "background" is a status flag, and detaching is flipping it.** There
is no separate foreground vs background execution path, so there is nothing to
reconcile.

- **One process object, one status.** `ShellCommandImpl` holds
  `#status: 'running' | 'backgrounded' | 'completed' | 'killed'` and a
  `TaskOutput` that *owns* all stdout/stderr. Foreground vs background is only
  *"is the current tool call still awaiting it, with a timeout?"*.
- **Output has one owner, and the medium follows whether the parent inspects it
  live.** `TaskOutput` owns a command's stdout+stderr either way. For plain bash
  (no in-flight inspection) it uses **file mode** — the child writes both fds
  **directly to a file** (`childProcess.stdout/.stderr` are `null`), the parent
  is blind, and small output is read back and the file deleted
  (`outputFileRedundant`) while large output stays as a pointer. For hooks (which
  must pattern-match output as it streams) it uses **pipe mode** — buffer in
  memory via `StreamWrapper`s and **spill to disk only on background**. Same
  owner, one retention story per command; the file-vs-memory choice is downstream
  of "does the parent need to see the bytes live?".
- **Detach = flip the flag** (`background(taskId)`): `running → backgrounded`,
  and the process + file are untouched (the child is already writing to the
  file). It only (a) starts a **size watchdog** — with the foreground timeout
  gone, a stuck append loop could fill the disk (their comment cites a *"768GB
  incident"*) — and (b) in pipe mode spills the in-memory buffer to disk so
  readers can find it.
- **Timeout decides detach vs kill** (`#handleTimeout`): if `#shouldAutoBackground`
  and an `onTimeout` callback is set, call `background()`; otherwise kill.
- **Inline output is full-or-pointer, never a lossy cap.** On completion, small
  output is returned inline and the file deleted (`outputFileRedundant`); output
  over `MAX_TASK_OUTPUT_BYTES` returns an `outputFilePath` + `outputFileSize`
  pointer instead. A backgrounded job whose file exceeds the cap is killed
  ("output file exceeded …").

**Why OpenSeek's first cut hit a wall.** OpenSeek has *two* output models —
foreground (in-memory, **prefix**-capped, **kill** on limit) and `bgjobs`
(in-memory, **tail**-capped, **keep running**). The dropped B2 tried to detach by
routing a foreground command *through* `bgjobs` on timeout, which forces those
two models to meet: prefix↔tail, kill↔run, notify↔don't. Every `codex review`
pass surfaced another mismatch. Claude Code never has this problem because a
command has **one** output owner with a single retention story — full output,
rendered inline-or-pointer — so "how much to show inline" is a *rendering*
decision, identical for foreground and background, not an execution decision.
(The *medium* underneath — file vs buffer-then-spill — varies, per the note
above, but that is invisible to callers.)

## Grounding in the current OpenSeek code

- `agent_tool/shell/shell.mbt` runs each command in a **per-call**
  `@async.with_task_group` and `hard_cancel`s on `timeout_ms` — the process
  cannot outlive the call; the shell parser bans `&`. Output is captured in
  memory as a **prefix** (`read_output_prefix`), cancelled on the char budget.
  Source-tree guards, the sandboxed launch (`agent_shell_launch`), moon command
  policy, and read-only review mode all run **before** spawn.
- `agent_tool/bgjobs` (shipped) is a session-scoped registry of jobs spawned on
  `scope.group()`, each with a `spawn_bg` monitor draining the pipe into an
  in-memory **tail** buffer; `on_job_exit` fires on natural exit.
- Push channel: `AgentRuntime.queue_steer()` / `drain_steers()`, drained at each
  step boundary; `apply_steer_inputs` folds each into the conversation.

## Status

Shipped (both open, `codex`-reviewed commit-by-commit; nothing merged):

- **PR #375** (`feat/background-shell`) — explicit background jobs: `bgjobs`
  runtime, `shell` `run_in_background`, `shell_output`, `shell_stop`.
- **PR #378** (`feat/background-shell-parity`, stacked) — push-completion:
  `on_job_exit → SteerInput::Notice`, injected live mid-turn or (idle serve
  engine) via a `BackgroundNotice` wake + an untagged `background_notice` event;
  persisted as `Runtime(RuntimeNotice)`. Plus `shell` docs.

These deliver the **tool surface and the push mechanism** — and they stay stable.
What is *not* yet Claude-Code-shaped is the **execution/output model
underneath**: two buffers (prefix vs tail), and no shared process object. The
work below re-bases the surface onto one shared execution with one output owner,
which is what makes detach-on-timeout fall out cleanly instead of fighting the
two models.

## Design decision — output medium: buffer-then-spill, not always-file

The unified sink (C1) keeps output **in memory up to the inline cap and spills to
a file past it** (and immediately on background) — i.e. Claude Code's *pipe/hooks*
medium, **not** its *always-file bash* medium. This is a deliberate divergence:

- **OpenSeek's shell inspects output in-flight** — sandbox-denial detection, the
  output-limit-and-cancel check, and TUI streaming all read bytes as they arrive.
  That needs the parent to see the stream; always-file (child → fd, parent blind)
  fights it. Claude Code itself buffers-then-spills exactly on the path that needs
  live inspection (hooks); OpenSeek's single shell path is on that side of the
  line, not the no-inspection bash side.
- **Command volume** — an agent runs a flood of tiny commands (`ls`, `git
  status`, `moon check`); always-file taxes every one with a temp file
  create/write/delete to optimize detach, which hits ~1 command in 1000.
- **Fewer files to orphan** — only large-or-backgrounded output ever touches
  disk, so there is far less temp state to clean up (Claude Code carries an
  explicit "another process deleted my output file" fallback for the always-file
  case).

Memory stays bounded because the spill threshold *is* the inline cap: anything
too big to show inline is already on disk. Always-file's one real edge — a
sustained huge stream never held in RAM — is captured this way too, without
paying disk cost on the common small command.

## Remaining work — converge on the single-execution model

**Implementation status (2026-07-07).** C1–C4 and C6 are implemented on branch
`feat/shell-execution-model`; C5 is intentionally a no-op. Notable deviation from
the design decision above: **C1 shipped as a bounded pure-memory sink, not
buffer-then-spill.** The sink retains the output prefix up to a hard cap in
memory and never writes a file — so memory is bounded (by the cap), foreground
in-flight inspection is preserved, and there is no disk to fill. Consequences:

- **C5 (size watchdog): not needed.** The watchdog guards a file from filling the
  disk; with no file spill there is no disk risk (the plan already noted the
  watchdog is only load-bearing once output spills to a file).
- **File-pointer for large output: deferred.** Large foreground output is still
  reported as the output-limit error (killed via `kill_when_full`), exactly as
  before — not yet a `<system>output_file=…>` pointer. Adding it means giving the
  sink an async spill path; a clean future enhancement, not required for the
  detach-on-timeout goal, which C1–C4 deliver.

Same commit gate as before: `moon fmt` → `moon check --target native <pkgs>` →
`moon test <pkgs>` → `codex review --base <prev-sha>` (background, read the
verdict, fix real findings, re-review clean) → drive the real tool where a
surface exists. A working-but-flawed detach spike is on `spike/detach-on-timeout`.

- **C1 — one output sink (`TaskOutput` analog).** Introduce a `ShellOutputSink`
  that owns a command's merged stdout+stderr: buffer in memory up to the inline
  cap, **spill to a file** under a session temp dir past it (or on background) —
  the buffer-then-spill medium from the design decision above, so the parent
  keeps reading the stream and in-flight inspection (sandbox denial, output
  limit) still works. Expose full read, tail-since-`seq`/offset, byte size, and
  an `inline_or_pointer` view (full text when small; a `<system>output_file=…
  size=…>` pointer when over the cap). This is the **one** retention policy — it
  replaces both the foreground prefix-cap and `bgjobs`' tail-cap. Keep the
  streaming-UTF-8 decode already in `bgjobs`. Pure infra + white-box tests;
  unwired.
- **C2 — one execution object (`ShellCommand` analog).** A `ShellExecution` with
  `status: Running | Backgrounded | Exited(Int) | Killed`, spawned on the
  **session group**, owning a `ShellOutputSink` and a monitor (reader task +
  `wait()`, as `bgjobs` already does). Foreground execution = start it, then
  await terminal-or-timeout. Re-point `bgjobs` at this: a backgrounded job is
  just a `ShellExecution` with `status = Backgrounded`, so `start`/`snapshot`/
  `list`/`stop` and `on_job_exit` become thin wrappers. The pre-spawn guards
  (source tree, sandbox, policy, read-only) are unchanged and still run in front.
- **C3 — foreground on the shared object.** Route `shell`'s foreground path
  through `ShellExecution` too (await it, render via `inline_or_pointer`), so
  foreground and background produce byte-identical results for the same output.
  The existing foreground output-limit **error** semantics are preserved as the
  small/complete case; large output becomes the file pointer (a behavior change
  worth its own note — the model reads the rest with `shell_output`).
- **C4 — detach-on-timeout = flip the status.** On `timeout_ms`, if auto-bg is
  on, `background()` the execution: `Running → Backgrounded`, keep the process +
  sink, return "moved to the background as `<id>`"; else cancel as today. No
  re-route, no second buffer — the mismatch that sank the first attempt is gone.
  Ship auto-bg **opt-in** first, flip the default once C1–C3 are proven.
- **C5 — size watchdog.** With the foreground timeout gone, a backgrounded
  execution watches its sink's byte size and kills the process past a hard cap
  (Claude Code's disk-fill guard). This is only load-bearing once a backgrounded
  job's output spills to a file (C1); until then `bgjobs`' bounded in-memory tail
  has no disk risk, which is why the shipped PRs omit it.
- **C6 — reconcile the tools + prompt.** `shell_output` tails the sink;
  `shell_stop` kills; push-completion fires from the terminal transition (B1's
  mechanism, unchanged). Update the `shell` description to state that a timed-out
  command detaches (not errors) and that large output returns a file pointer.

## Test plan

Principles (every commit): **native target** (async spawn); **deterministic
polling** — bounded ticks + `@async.sleep`, `fail(...)` on a deadline, fast
commands (`printf`, `exit N`) with a real sleeper only for stop/timeout;
**isolation** — parallel async tests, per-test temp cwd/sink dir, no shared
files; **regression** — the full `agent_tool/shell` suite stays green, and
foreground results stay byte-identical for the same output until the C3/C4
behavior notes land (large-output pointer; timeout-detach), each gated behind its
flag/commit.

Shipped coverage (keep green): `bgjobs` white-box (exit codes, stop, output cap,
descendant-holds-pipe, closed-streams stop race, UTF-8 boundary, `on_job_exit`
fires once on natural exit / never on stop); `shell` `run_in_background`
(id + fast return, guards enforced before spawn, `timeout_ms` rejected with it);
`shell_output`/`shell_stop` (poll, unknown id, stop → Stopped); the push path
(notice decode, serve idle-wake untagged event, TUI `⚙` render).

Per new commit:

- **C1 (sink)** — small output → inline, no file, `inline_or_pointer` is full
  text; output over the cap → spills to a file, `inline_or_pointer` is a pointer
  with the right size, full read returns everything (prefix intact — the *start*
  of errors is visible, unlike a tail); tail-since-`seq` returns only new bytes;
  UTF-8 split across the spill boundary is not corrupted.
- **C2 (execution)** — a `ShellExecution` reaches `Exited(code)`; `bgjobs` wrappers
  still pass every shipped test unchanged; teardown reaps a `Backgrounded` job.
- **C3 (foreground on shared object)** — a foreground command returns the same
  bytes as before for small output; a command over the cap returns the file
  pointer and `shell_output` reads the remainder; the output-limit **error** case
  is preserved for the small/complete path.
- **C4 (detach-on-timeout)** — command outliving a small `timeout_ms` with auto-bg
  on → "moved to the background as `<id>`", job continues then exits, **prefix**
  output preserved (not a tail); auto-bg off → today's timeout-error/kill; a
  runaway producer is killed on the size cap, not silently backgrounded forever.
- **C5 (watchdog)** — a backgrounded unbounded producer is killed once its file
  passes the hard cap; a bounded one is not.
- **C6 (tools/prompt)** — `shell_output` tails a live job and returns the full
  file after exit; description strings mention detach-on-timeout + the file
  pointer + `shell_output`/`shell_stop`.
