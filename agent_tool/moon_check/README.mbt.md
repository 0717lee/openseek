# Moon Check Tool

`moon_check` starts or reuses a session-scoped
`moon check --watch --output-json` watcher and returns the latest merged
stdout/stderr snapshot. It is a focused validation tool for MoonBit work: use
it when the agent needs compiler feedback without going through `sh -c` or
manually polling one-shot checks.

## Design Rationale

`moon_check` exists separately from `shell` and `moon_cmd` because compiler
diagnostics are the tightest feedback loop in MoonBit work. It always runs
`moon check --watch --output-json`, which gives the agent structured locations
and messages without depending on a shell pipeline or a human-readable
formatter. The first call for a given cwd/path/options tuple starts a watcher;
later calls with the same tuple reuse the existing watcher and return the
latest snapshot.

The schema is intentionally narrow. It accepts MoonBit check options that affect
diagnostics, but it does not expose unrelated `moon` subcommands. That narrow
shape nudges the agent to check early and often while keeping compile feedback
separate from tests, CLI runs, formatting, and interface generation.

## API Style

Use `moon_check` once at the start of an iterative MoonBit edit loop, especially
after creating or editing a package file:

```json
{
  "cwd": "/tmp/example_project",
  "path": "src/parser",
  "target": "native"
}
```

Use `warn_list` or `deny_warn` when the task requires stricter cleanup. The
agent may call `moon_check` again to inspect the current watcher state; the call
does not start a duplicate watcher for the same arguments. Use `moon_cmd` for
`moon test`, `moon run`, `moon info`, `moon fmt`, or user-facing command
validation.

## Arguments

| Name | Type | Required | Notes |
| --- | --- | --- | --- |
| `cwd` | string | no | Working directory. Empty is treated as missing. |
| `path` | string | no | One package path passed as `--package-path`. |
| `paths` | string array | no | Additional paths; watch mode rejects more than one total path. |
| `target` | string | no | `wasm`, `wasm-gc`, `js`, `native`, `llvm`, or `all`. |
| `warn_list` | string | no | Value passed to `--warn-list`. |
| `deny_warn` | boolean | no | Adds `--deny-warn` when true. |
| `fmt` | boolean | no | Adds `--fmt` when true. |
| `explain` | boolean | no | Adds `--explain` when true. |

## Action

The action is always `Respond(ToolOutput(...))`. `is_error` is true when the
latest watcher snapshot has compiler errors, when argument validation fails, or
when the process cannot be launched. The string body has one of these shapes:

- `"cwd=<cwd>\ncommand=moon check --watch --output-json ...\nwatcher=<started|reused|restarted>\nid=<id>\nstatus=<running|stopped>\nseq=<n>\n<output>"`.
- `"error running moon_check: <error>"`.
- `"error: moon_check requires <field description>"`.

## Example

```moonbit check
///|
async test "moon_check tool advertises the expected schema" {
  @async.with_task_group() <| group => {
    let tool = @moon_check.definition(AgentRuntime(group))
    assert_eq(tool.name, "moon_check")
    let JsonSchema(schema) = tool.schema
    let text = schema.stringify()
    assert_true(text.contains("\"path\""))
    assert_true(text.contains("\"target\""))
  }
}
```

Process execution is intentionally not exercised from doc tests: running
`moon check` against the active package from inside `moon test` can contend with
the active build. The real-world unit tests copy fixture projects into `/tmp`
and run `moon_check` there, covering both a valid project and a broken project
that emits compiler diagnostics.
