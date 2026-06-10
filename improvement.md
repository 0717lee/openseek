# Improvement Checklist

Observations collected while working on streaming, sessions, and documentation
(June 2026). Each item is small enough to land as its own PR; none blocks
current functionality. Check items off as they land, and add new ones at the
bottom of the matching section.

## TUI

- [x] **Collapse the triple redraw per message.** `refresh_ui` calls
  `set_status`, `set_activity`, and `set_queued_inputs`, each of which queues
  its own full-frame redraw — three repaints per message-loop iteration.
  During delta bursts this triples render work. Add a single
  "set view state + one redraw" command on `Ui`. *(Done: `Ui::set_live_view`
  replaces the three setters; one command, one redraw per loop turn.)*
- [x] **Keep reasoning visible after the turn.** Thinking-mode reasoning only
  ever exists as the transient `Thinking …` tail and is discarded once
  content starts. Surface it as a dimmed/collapsible transcript item so a
  user can review *why* the model did something. *(Done: the engine emits
  `reasoning_message` after streaming; the TUI commits a `✻` thought aside
  above the answer. Resume does not replay thoughts — sessions do not store
  reasoning for no-tool turns; see the auto-compaction/session items.)*
- [x] **Measure the activity label instead of reserving 13 columns.**
  `ActivityPreviewReservedColumns` hardcodes indent + widest label + slack;
  computing it from the actual label keeps the preview honest if labels
  change. *(Done: `streaming_activity_line` measures the label's display
  width; only the renderer indent + slack remain a constant.)*
- [x] **`--continue` resumes the most recent session.** *(Done:
  `SessionStore::latest` picks the most recently active session by event-log
  mtime; `openseek-tui --continue` resumes it, errors when combined with
  `--session`, and starts fresh on an empty store.)*
- [ ] **Session switching inside the TUI.** A way to list and switch sessions
  without restarting. Generated ids (`tui-YYYYMMDD-HHMMSS-mmm`) are only
  discoverable via the startup banner or `openseek --session-list` today.
- [x] **Steering a running task.** `Steer` while running is rejected ("press
  Tab to queue") because the engine cannot accept mid-turn input. Needs an
  engine-side protocol (e.g. a control channel on stdin) before the TUI can
  offer it. *(Done: Enter while running steers — the text rides the serve
  protocol's lossless channel, lands at the turn's next step boundary, wins
  over model-initiated completion, and is echoed into the transcript at the
  position the model actually saw it.)*
- [x] **Persistent engine per session.** The TUI spawns a fresh engine per
  prompt, so `moon_check --watch` restarts (and re-warms) every turn and its
  watcher state is lost between prompts. A long-lived engine process per
  session — with prompts delivered over a channel — would keep watchers warm
  and is also the prerequisite for steering. *(Done: one `--serve` engine per
  TUI session — JSONL commands on stdin, shared runtime and tool registry
  across turns, Ctrl-C cancel → kill escalation, respawn on death from the
  durable session.)*

## Engine / agent

- [x] **Expose thinking controls.** `run_with_runtime` hardcodes
  `thinking=Enabled, reasoning_effort=Max`; make them engine flags
  (`--thinking`, `--reasoning-effort`) and TUI pass-throughs. *(Done:
  `OPENSEEK_THINKING` / `OPENSEEK_REASONING_EFFORT` env-backed flags on both
  binaries, threaded through `@agent.run*` as optional params with the old
  hardcoded values as defaults.)*
- [ ] **Auto-compaction.** Compaction exists only as the manual
  `--session-compact-*` flow. Long-lived sessions (now the TUI default)
  grow without bound; trigger summarization when the projected context
  passes a threshold.
- [x] **Richer `--session-list`.** Bare ids are hard to recognize; include
  last-activity time and the first user prompt as a label. *(Done:
  `SessionStore::listings` returns id + last-activity + first prompt, newest
  first with unreadable sessions kept visible for cleanup; the CLI prints
  tab-separated rows, so `| cut -f1` recovers the old bare-id output.)*
- [ ] **Stale `session.lock` recovery.** Verify what happens when an engine
  crashes while holding the lock, and document (or implement) the recovery
  path.
- [ ] **Flush the JSONL queue on hard crash.** The stdout drain trades
  crash-tail durability for purity (no C stub): lines queued but unwritten
  when the process aborts are lost. A panic hook that drains synchronously
  would close the gap.
- [ ] **Cheapen the engine probe.** `engine_launchable` spawns
  `<engine> --help` on every TUI launch; cache the result per engine path
  (mtime-keyed) or accept the first spawn failing fast instead.

## DeepSeek client

- [ ] **Unify `chat` and `chat_stream`.** They share request encoding but
  duplicate response and error handling. Implementing `chat` as
  streaming-with-no-callbacks leaves one wire path to maintain.
- [ ] **Retry transient HTTP failures.** Both entry points are single-shot;
  a bounded retry with backoff on connect/5xx errors would remove the most
  common spurious turn failures.

## Testing / CI

- [ ] **More CI platforms.** CI is a single `check (nightly)` job; the TUI's
  pty handling and the engine's stdio behavior are platform-sensitive
  (macOS pty quirks surfaced during verification). Add macOS, then Windows.
- [x] **Make the live cram lifecycle test extension-proof.** It asserts an
  exact event-name set and broke when `*_delta` events were added (now
  filtered). Assert the stable lifecycle subset is *present* instead of
  asserting the full set. *(Done: the example whitelists the lifecycle
  events, so new payload event kinds cannot break it.)*
- [ ] **Checked-in TUI integration harness.** The pty driver used to verify
  streaming and session memory lives outside the repo. Pair a small pty
  driver with a recorded-stream replay engine (the TUI already accepts
  `--engine <replayer>`) for deterministic offline TUI tests.
- [ ] **Run `moon fmt --check` before push.** Two consecutive PRs hit
  CI-only formatting failures; a pre-push hook or documented `moon` alias
  would catch them locally.
- [ ] **CI does not exercise the JS packages.** `ci.yml` runs `moon check` /
  `moon test` on the default (native) target only, so the visualizer's
  js-only packages (`viz`, `cmd/viz_app`) are silently skipped — they
  compile and pass locally but a regression there would not fail CI today.
  Add a `--target js` check/test step (or a target matrix). Their logic is
  currently covered only by local unit tests + a headless-browser run.

## Docs / prompts

- [ ] **Doc-exemplary prompt examples.** `prompt/moon.pkg` opts the system
  prompt out of `missing_doc` because its example code blocks are
  model-facing text. Consider documenting those examples *as a prompt
  change* (with an eval run) so the model also learns the doc convention.
- [x] **Document the TUI session default.** The root README does not yet
  mention that every TUI launch converses in a durable session and how to
  resume one (`--session <id>` from the startup banner). *(Done: the README
  gains a Terminal UI section covering default sessions, `--continue`,
  `--session`, and the enriched `--session-list`, plus a `cmd/tui` row in
  the packages table.)*

## Visualizer (viz)

Follow-ups for the `events.jsonl` web viewer (`viz`, `cmd/viz_server`,
`cmd/viz_app`, `web/`).

- [ ] **Smarter `--session-root` default discovery.** The default is the
  relative `.openseek`, resolved against the server's cwd; `moon run
  cmd/viz_server` uses the module root as cwd (no `.openseek` there), so the
  no-arg case shows nothing. Walk up from cwd to the nearest `.openseek`
  (like git finds `.git`) so the default "just works" from a subdirectory.
- [ ] **Optional self-contained binary for distribution.** Today the server
  serves `web/index.html` from disk and auto-locates the built `viz_app.js`
  from `_build/`. If we ever want to *ship* the viewer as one binary, embed
  both via the `md_to_mbt_string`-style `rule` and accept the js→embed→native
  build order. Not worth it for a local dev tool; embedding only the HTML is
  a half-measure (the binary still needs the JS), so it is all-or-nothing.
- [ ] **UI polish.** Sidebar: show the last-active timestamp (the server
  already returns it; the frontend ignores it). Turn headers: show a per-turn
  summary (tool count, terminal status) on the collapsed `<details>` line.
  Tool cards: collapse long output by default with an expand toggle.
  Navigation: jump-to-errors, text search/filter, expand/collapse all.
- [ ] **Persist the theme choice.** The Light/Dark/System toggle resets to
  Light on reload; persist it (localStorage) so the choice sticks.

## MoonBit toolchain & DX

Observations from building the visualizer (native server + JS frontend in
one module). These are toolchain/language ergonomics — several are likely
upstream `moon`/MoonBit items rather than openseek changes — but they cost
real time and are worth tracking.

- [ ] **`moon info` does not generate `.mbti` for js-only packages.** In a
  module whose canonical backend is native, `moon info` writes no
  `pkg.generated.mbti` for `supported_targets = "js"` packages — it only
  prints a perpetual "requested interfaces different from canonical backend
  Native" diff. I had to hand-copy the generated interface out of `_build/`.
  A per-package canonical backend (or `moon info --target js` writing the
  files) would fix it.
- [ ] **No cross-target build dependency.** `moon build` is per-target, so
  there is no way to express "build the JS bundle, then embed it into the
  native binary" in one invocation — it forces a manual two-step. This is
  the root reason the viz bundle is served from disk rather than embedded.
- [ ] **Library aborts are invisible and uncontainable.** A second
  `send_response` on a connection hit a `guard … else`-less panic (abort) in
  `@async/http` that tore down `run_forever`; neither `catch` (handles
  `Error`, not panics) nor `allow_failure` contained it. Checked errors are
  tracked in signatures, but panics/aborts are not — so you cannot tell which
  library calls can kill the process. Surfacing "can abort", or a task
  boundary that contains aborts, would make robust server code tractable.
  *(Worked around in viz by computing each reply before a single send.)*
- [ ] **Default trait methods are not callable through a trait object.**
  `@fs.read_file` returns `&@io.Data`; the *required* `binary()`/`text()`
  dispatch fine, but the *default* `to_bytes()`/`to_bytesview()` fail with
  `[4039] Cannot use method … of abstract trait`. The required-vs-default
  rule through `&Trait` is non-obvious and cost compile cycles.
- [ ] **A `moon fix` autofixer for deprecations.** A lot of small edit cycles
  came from deprecation warnings with mechanical rewrites: `not(x)`→`!x`,
  `StringView::to_string`→`to_owned`, `String::substring`→view slicing,
  `@strconv.parse_int`→`@string.parse_int`, `derive(Show)`→`derive(Debug)`,
  plus `+unnecessary_annotation` cascading. An autofix (à la `moon fmt`)
  would erase most of these.
- [ ] **Lint a `..` cascade that discards a non-unit return.** `session..append(x)`
  on an immutable builder (where `append` returns a *new* `Session`) compiles
  and silently no-ops — it caused a real test bug. Warn when `..` drops a
  non-`Unit` result.
- [ ] **Surface dependency examples/APIs in `moon ide doc`.** Learning
  third-party APIs (rabbita's callable `Emit`, `@async/http.Server::Server`,
  `@utf8.decode_lossy`, `&Data::binary`) meant grepping `.mooncakes`/`.repos`.
  Examples like `http_file_server` were invaluable once found; surfacing dep
  docs/examples through `moon ide doc` would shortcut discovery.
