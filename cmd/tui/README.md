# bobzhang/openseek/cmd/tui

The OpenSeek terminal UI: a scrolling transcript with a live composer, built
on the reusable [`tui`](../../tui/README.md) controller package.

The TUI runs no agent code itself. It spawns the engine binary (`openseek`
from `PATH`; override with `--engine` or `OPENSEEK_ENGINE`) **once per
session** in `--serve` mode and drives it over stdin commands, rendering the
engine's JSONL event stream: streamed thinking and answer text move live on
the activity line, each turn's reasoning is kept as a dim `✻` transcript
aside above its answer, and tool results land as `⏺` blocks. Pressing Enter
while a task runs steers it mid-turn; Ctrl-C cancels the turn (a second
Ctrl-C kills the engine, and the next prompt respawns it on the same
session).

A custom or recorded-stream engine that only speaks the original
one-process-per-prompt protocol still works with `--engine-mode oneshot`
(env `OPENSEEK_ENGINE_MODE`); steering is unavailable there.

## Workspaces and sessions

Launching the TUI in a directory opens that directory's *workspace*, the way
`code .` does. A workspace's sessions live in the project's own `.openseek/`
— they travel (and die) with the project — while the global OpenSeek home at
`~/.openseek` (override with `OPENSEEK_HOME`) only *indexes* which workspaces
exist, so conversations are found again from anywhere, not only from the
directory that created them. To open another project's workspace, launch the
TUI there; `--workspace-list` prints known workspaces, most recently opened
first.

Every launch converses in a durable session — the engine only carries context
between prompts through the session store, so without one each prompt would be
an amnesiac one-shot. A generated id (`tui-YYYYMMDD-HHMMSS-mmm`, named in the
startup banner) stores the conversation in the workspace's store.

- `--continue` resumes the workspace's most recently active session.
- `--session <id>` resumes (or creates) a specific one; combining it with
  `--continue` is rejected.
- `openseek --session-list --session-root <store>` (on the engine CLI) lists
  what is resumable.
- `--session-root <dir>` bypasses the workspace layer entirely and uses the
  given store as-is (nothing is indexed under the home).

## Configuration

`--api-key` (env `DEEPSEEK`) is required. `--model`, `--api-url`,
`--max-steps`, and `--thinking` mirror the engine's flags and are forwarded to
it through the environment, alongside the session settings.

The full flag reference lives in the executable help — verified verbatim in
[`tests/cram/tui.md`](../../tests/cram/tui.md).
