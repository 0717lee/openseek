# Verified OpenSeek CLI Documentation

These examples are executed by `moon cram test tests/cram`. The Moon wrapper
builds the native package at `cmd/openseek` first, then exposes the executable
on `PATH` as `openseek.exe`.

`openseek` is a subcommand tree: the interactive terminal UI is the default
(documented in [`tui.md`](tui.md)), and the headless engine lives under `run`,
`serve`, `review`, and `sessions`. Every command here is offline: it either
prints help or fails argument validation before the agent contacts DeepSeek, so
the suite needs no API key and makes no network calls. The live, API-backed
examples live in [`tests/live/deepseek.md`](../live/deepseek.md).

## Top-Level Help

`openseek --help` lists the subcommands and exits successfully.

```mooncram
$ openseek.exe --help
openseek — DeepSeek-backed MoonBit coding agent

Usage:
  openseek [--prompt "…"]        Launch the interactive terminal UI (default).
  openseek tui [--prompt "…"]    The interactive UI, explicitly.
  openseek run [options] TASK    Run one task headlessly; stream JSONL on stdout.
  openseek serve                 JSONL command server (stdin: prompt/steer/cancel/compact).
  openseek review [--base REF]   Read-only code review of REF...HEAD; one JSON report.
  openseek sessions <list|show|compact>   Manage durable sessions.

Run `openseek <subcommand> --help` for a subcommand's options.
```

## A Misspelled Subcommand Is An Error, Not A Prompt

There is no free-form top-level prompt: a bare word that is not a subcommand is
treated as a typo and rejected — with a suggestion when it is close — rather than
silently opening the UI with that word as a prompt.

```mooncram
$ openseek.exe serv 2>&1
error: unknown command `serv`; did you mean `serve`?
Run `openseek --help` for commands, or `openseek --prompt "…"` to open the UI with a prompt.
[1]
```

A token that resembles nothing gets a clean error without a bogus suggestion.

```mooncram
$ openseek.exe frobnicate 2>&1
error: unknown command `frobnicate`
Run `openseek --help` for commands, or `openseek --prompt "…"` to open the UI with a prompt.
[1]
```

## Top-Level Flags Open The UI; A Prompt Comes From `--prompt`

A leading flag (no subcommand) runs the interactive UI, and `--prompt` supplies
an initial prompt. Offline, this reaches the engine preflight — pointed here at a
missing engine so it fails deterministically without the network, which also
proves `--prompt` was accepted (not rejected as an unexpected argument).

```mooncram
$ env DEEPSEEK=test-key openseek.exe --engine does-not-exist --prompt "inspect project" 2>&1
error: engine 'does-not-exist' is not usable: it must be on PATH, executable, and accept `--help` (exit 0) the way openseek does.
Pass --engine <path>, set OPENSEEK_ENGINE, or install the openseek binary.
[1]
```

With no free-form positional, `--` no longer smuggles a prompt: a value after it
is rejected by the parser rather than opening the UI.

```mooncram
$ sh <<'EOF'
> stderr=$(mktemp)
> if env DEEPSEEK=test-key openseek.exe -- something 2> "$stderr" >/dev/null; then echo exit-zero; else echo exit-non-zero; fi
> sed -n '1p' "$stderr"
> rm -f "$stderr"
> EOF
exit-non-zero
error: unexpected value 'something' found; no more were expected
```

A leading `-` of any kind routes to the UI (never a subcommand). A lone `--`
opens the UI with no prompt, so it still needs an API key like any UI launch:

```mooncram
$ sh <<'EOF'
> stderr=$(mktemp)
> if env -u DEEPSEEK openseek.exe -- 2> "$stderr" >/dev/null; then echo exit-zero; else echo exit-non-zero; fi
> sed -n '1p' "$stderr"
> rm -f "$stderr"
> EOF
exit-non-zero
error: the following required argument was not provided: 'api-key'
```

A lone `-` routes to the UI too, where the parser rejects it as a stray value.

```mooncram
$ sh <<'EOF'
> stderr=$(mktemp)
> if env DEEPSEEK=test-key openseek.exe - 2> "$stderr" >/dev/null; then echo exit-zero; else echo exit-non-zero; fi
> sed -n '1p' "$stderr"
> rm -f "$stderr"
> EOF
exit-non-zero
error: unexpected value '-' found; no more were expected
```

## `openseek run` Runs One Task Headlessly

`openseek run --help` prints the options, environment variables, and defaults
behind a headless run.

```mooncram
$ openseek.exe run --help
Usage: openseek run [options] [task...]

Run one task headlessly; stream JSONL events on stdout.

Arguments:
  task...  Task description.

Options:
  -h, --help                                                   Show help information.
  --no-session                                                 Run ephemerally: do not record this run to a durable session.
  --api-key <api-key>                                          DeepSeek API key. [env: DEEPSEEK] [default: ]
  --model <model>                                              DeepSeek model: deepseek-v4-flash or deepseek-v4-pro. [env: DEEPSEEK_MODEL] [default: deepseek-v4-pro]
  --api-url <api-url>                                          DeepSeek-compatible chat completions endpoint. [env: OPENSEEK_API_URL] [default: ]
  --dir <dir>                                                  Workspace directory for relative paths; creates only the final path component if its parent exists. [env: OPENSEEK_DIR] [default: .]
  --max-steps <max-steps>                                      Maximum number of agent loop steps before stopping. [env: OPENSEEK_MAX_STEPS] [default: 1000]
  --thinking <thinking>                                        DeepSeek thinking mode: no, high, or max. [env: OPENSEEK_THINKING] [default: max]
  --system-prompt-file <system-prompt-file>                    Read the complete system prompt from this file instead of the built-in prompt. [env: OPENSEEK_SYSTEM_PROMPT_FILE] [default: ]
  --system-prompt-addendum-file <system-prompt-addendum-file>  Append this file to the selected system prompt for prompt experiments. [env: OPENSEEK_SYSTEM_PROMPT_ADDENDUM_FILE] [default: ]
  --global-skills-dir <global-skills-dir>                      User-level skills directory advertised alongside workspace skills; empty means $HOME/.openseek/skills, or %USERPROFILE%/.openseek/skills on Windows. [env: OPENSEEK_GLOBAL_SKILLS_DIR] [default: ]
  --session <session>                                          Create or resume this durable session id. [env: OPENSEEK_SESSION] [default: ]
  --session-root <session-root>                                Directory containing durable OpenSeek sessions. [env: OPENSEEK_SESSION_ROOT] [default: .openseek]
  --concurrency <concurrency>                                  Run the task in N sibling copies of --dir concurrently (best-of-N); 1 means a single run. [env: OPENSEEK_CONCURRENCY] [default: 1]
```

## A DeepSeek API Key Is Required For Agent Runs

With no `--api-key` flag and no `DEEPSEEK` in the environment, a run reports the
missing key and exits non-zero.

```mooncram
$ sh <<'EOF'
> stdout=$(mktemp)
> stderr=$(mktemp)
> if env -u DEEPSEEK openseek.exe run "summarize this project" > "$stdout" 2> "$stderr"; then echo exit-zero; else echo exit-non-zero; fi
> cat "$stderr"
> if test -s "$stdout"; then echo stdout-not-empty; else echo stdout-empty; fi
> rm -f "$stdout" "$stderr"
> EOF
exit-non-zero
error: --api-key or DEEPSEEK is required for agent runs
stdout-empty
```

## Unknown Options Are Rejected Before Task Text

The task is free-form after option parsing has stopped, but a leading
option-looking token is still an option. This catches stale or misspelled flags
instead of silently turning them into prompt text.

```mooncram
$ sh <<'EOF'
> stdout=$(mktemp)
> stderr=$(mktemp)
> if env -u DEEPSEEK openseek.exe run --xxy he > "$stdout" 2> "$stderr"; then echo exit-zero; else echo exit-non-zero; fi
> sed -n '1p' "$stderr"
> if test -s "$stdout"; then echo stdout-not-empty; else echo stdout-empty; fi
> rm -f "$stdout" "$stderr"
> EOF
exit-non-zero
error: unexpected argument '--xxy' found
stdout-empty
```

When the task itself must start with `-`, use the normal option delimiter.
Here parsing succeeds and the run reaches the later API-key validation.

```mooncram
$ sh <<'EOF'
> stdout=$(mktemp)
> stderr=$(mktemp)
> if env -u DEEPSEEK openseek.exe run -- '--xxy he' > "$stdout" 2> "$stderr"; then echo exit-zero; else echo exit-non-zero; fi
> cat "$stderr"
> if test -s "$stdout"; then echo stdout-not-empty; else echo stdout-empty; fi
> rm -f "$stdout" "$stderr"
> EOF
exit-non-zero
error: --api-key or DEEPSEEK is required for agent runs
stdout-empty
```

## `openseek sessions` Is Offline

Session inspection and compaction operate on typed session files and do not
require a DeepSeek API key. Hand-written log lines carry the 0 sentinel stamp;
the summary event the compaction *appends* is stamped with the wall clock, so
both `sessions show` calls strip `ts` to stay deterministic.

```mooncram
$ sh <<'EOF'
> tmp=$(mktemp -d)
> mkdir -p "$tmp/sessions/demo"
> printf '{"version":1,"id":"demo","system_prompt":"system","last_sequence":2}' > "$tmp/sessions/demo/session.json"
> cat > "$tmp/sessions/demo/events.jsonl" <<'JSONL'
> {"sequence":1,"ts":0,"item":{"kind":"user","payload":{"content":"hello"}}}
> {"sequence":2,"ts":0,"item":{"kind":"assistant","payload":{"content":"answer","tool_calls":[]}}}
> JSONL
> printf 'hello and answer' > "$tmp/summary.txt"
> env -u DEEPSEEK openseek.exe sessions list --session-root "$tmp" | cut -f1
> env -u DEEPSEEK openseek.exe sessions show demo --session-root "$tmp" | sed -E 's/"ts":[0-9]+,//g'
> env -u DEEPSEEK openseek.exe sessions compact demo --session-root "$tmp" --file "$tmp/summary.txt" --from 1 --to 2
> env -u DEEPSEEK openseek.exe sessions show demo --session-root "$tmp" | sed -E 's/"ts":[0-9]+,//g'
> rm -rf "$tmp"
> EOF
demo
{"version":1,"id":"demo","system_prompt":"system","events":[{"sequence":1,"item":{"kind":"user","payload":{"content":"hello"}}},{"sequence":2,"item":{"kind":"assistant","payload":{"content":"answer","tool_calls":[]}}}]}
compacted session demo events 1..2; last_sequence=3
{"version":1,"id":"demo","system_prompt":"system","events":[{"sequence":1,"item":{"kind":"user","payload":{"content":"hello"}}},{"sequence":2,"item":{"kind":"assistant","payload":{"content":"answer","tool_calls":[]}}},{"sequence":3,"item":{"kind":"summary","payload":{"content":"hello and answer","from_sequence":1,"to_sequence":2}}}]}
```

## `openseek run` Records A Session By Default

`openseek run "task"` records its conversation to a generated
`cli-YYYYMMDD-HHMMSS-mmm` session under `--session-root` (default `.openseek`),
exactly as if `--session` had been passed — "what did the agent do?" is usually
asked after the run, when an unrecorded answer is gone for good. The run
announces the recording with a `session_started` event on stdout, so the id is
in the log stream (and any `OPENSEEK_LOG_FILE` mirror); afterwards the run is
visible to `sessions list`, `sessions show`, the viz server, and `--session
<id>` resumption.

This example stays offline by pointing `--api-url` at a closed local port: the
engine names its session, durably records the user prompt, and only then fails
to reach the API. The generated id's timestamp is normalized for determinism.

```mooncram
$ sh <<'EOF'
> tmp=$(mktemp -d)
> cd "$tmp"
> if env DEEPSEEK=test-key openseek.exe run --api-url "http://127.0.0.1:9/chat/completions" "say hi" > out.jsonl 2>/dev/null; then echo exit-zero; else echo exit-non-zero; fi
> grep -c '"event":"session_started"' out.jsonl
> env -u DEEPSEEK openseek.exe sessions list | cut -f1 | sed -E 's/cli-[0-9]{8}-[0-9]{6}-[0-9]{3}(-[A-Za-z0-9]+)?/cli-<stamp>/'
> rm -rf "$tmp"
> EOF
exit-non-zero
1
cli-<stamp>
```

`--no-session` turns recording off: the same failing run leaves no session root
behind.

```mooncram
$ sh <<'EOF'
> tmp=$(mktemp -d)
> cd "$tmp"
> env DEEPSEEK=test-key openseek.exe run --no-session --api-url "http://127.0.0.1:9/chat/completions" "say hi" >/dev/null 2>&1
> if test -d .openseek; then echo recorded; else echo ephemeral; fi
> rm -rf "$tmp"
> EOF
ephemeral
```

## `--dir` Selects The Workspace Root

`--dir` defaults to `.`, but it can point a run at another workspace. When the
final path component is missing and the parent exists, OpenSeek creates that one
directory, logs `workspace_created`, and resolves the default session root under
it.

```mooncram
$ sh <<'EOF'
> tmp=$(mktemp -d)
> mkdir -p "$tmp/parent"
> if env DEEPSEEK=test-key openseek.exe run --dir "$tmp/parent/new" --api-url "http://127.0.0.1:9/chat/completions" "say hi" > "$tmp/out.jsonl" 2>/dev/null; then echo exit-zero; else echo exit-non-zero; fi
> if test -d "$tmp/parent/new"; then echo dir-created; else echo dir-missing; fi
> grep -c '"event":"workspace_created"' "$tmp/out.jsonl"
> env -u DEEPSEEK openseek.exe sessions list --dir "$tmp/parent/new" | cut -f1 | sed -E 's/cli-[0-9]{8}-[0-9]{6}-[0-9]{3}(-[A-Za-z0-9]+)?/cli-<stamp>/'
> env -u DEEPSEEK openseek.exe sessions list --dir "$tmp/parent/fresh" > "$tmp/session-list.out"
> if test -d "$tmp/parent/fresh"; then echo session-dir-created; else echo session-dir-missing; fi
> wc -l < "$tmp/session-list.out" | tr -d ' '
> rm -rf "$tmp"
> EOF
exit-non-zero
dir-created
1
cli-<stamp>
session-dir-created
0
```

Asking for both recording behaviors at once is rejected before any work happens.

```mooncram
$ env DEEPSEEK=test-key openseek.exe run --session demo --no-session "say hi" 2>&1
error: --no-session contradicts --session; pick one behavior
[1]
```

## `openseek serve` Speaks JSONL Commands On Stdin

`serve` turns the engine into a long-lived session server: prompts, steers, and
cancels arrive as JSONL commands on stdin, and the usual event stream leaves on
stdout. The command surface is testable offline — a malformed command is
reported as a `command_error` event rather than killing the server, an idle
`cancel` is a no-op, and stdin EOF shuts the server down cleanly (exit 0)
without ever touching the network. The `grep -o` keeps only the stable event
tag, since event lines carry timestamps.

```mooncram
$ printf '{"command":"reboot"}\n{"command":"cancel"}\n' | env DEEPSEEK=test-key openseek.exe serve 2>/dev/null | grep -o '"event":"command_error"'
"event":"command_error"
```

A steer with no turn to land in is rejected rather than converted into a prompt:
it can only arrive idle by racing a turn's terminal event through the pipes, and
an engine must never start a turn the controller did not ask for. The rejection
carries a `steer_dropped` event so the controller can ask the user to resubmit —
and, usefully for this offline test, no turn means no network.

```mooncram
$ printf '{"command":"steer","text":"too late"}\n' | env DEEPSEEK=test-key openseek.exe serve 2>/dev/null | grep -o '"event":"steer_dropped"'
"event":"steer_dropped"
```

`serve` takes no positional; a stray task is rejected by the parser before
anything runs.

```mooncram
$ sh <<'EOF'
> stderr=$(mktemp)
> if env DEEPSEEK=test-key openseek.exe serve "do something" 2> "$stderr" >/dev/null; then echo exit-zero; else echo exit-non-zero; fi
> sed -n '1p' "$stderr"
> rm -f "$stderr"
> EOF
exit-non-zero
error: unexpected value 'do something' found; no more were expected
```

## MoonBit CLI Argument Parsing Pattern

Native MoonBit CLIs should use `moonbitlang/core/argparse` and call
`@argparse.parse(...)` on a `Command` instead of hand-rolling argument parsing
with `@env.args()`. This tiny package verifies the current `FlagArg`,
`PositionArg`, and `Matches` shape.

```mooncram
$ sh <<'EOF'
> tmp=$(mktemp -d)
> mkdir -p "$tmp/cmd/echoargs"
> cat > "$tmp/moon.mod" <<'MOD'
> name = "example/cli"
> version = "0.1.0"
> MOD
> cat > "$tmp/cmd/echoargs/moon.pkg" <<'PKG'
> import {
>   "moonbitlang/core/argparse"
> }
> warnings = "+unnecessary_annotation"
> supported_targets = "+native"
> options(
>   "is-main": true,
> )
> PKG
> cat > "$tmp/cmd/echoargs/main.mbt" <<'MBT'
> ///|
> fn main raise {
>   let matches = @argparse.parse(
>     Command(
>       "echoargs",
>       about="Tiny argparse example.",
>       flags=[FlagArg("stdin", long="stdin", about="Read stdin.")],
>       positionals=[PositionArg("input", default_values=["-"])],
>     ),
>   )
>   let input = match matches.values.get("input") {
>     Some([value, ..]) => value
>     _ => fail("missing input")
>   }
>   let stdin = match matches.flags.get("stdin") {
>     Some(value) => value
>     None => false
>   }
>   println("input=\{input}")
>   println("stdin=\{stdin}")
> }
> MBT
> (cd "$tmp" && moon run --target native cmd/echoargs -- --stdin sample.toml)
> rm -rf "$tmp"
> EOF
input=sample.toml
stdin=true
```
