# Shell Tool

`shell` runs a command line through the platform shell and returns the exit code
together with the merged stdout/stderr output. On Windows that shell is
`pwsh -NoProfile -Command` and callers should use PowerShell syntax; elsewhere
it is `sh -c` and callers should use POSIX shell syntax. It is the agent's
escape hatch for running build commands, tests, package managers, version-control
operations, and any other workspace task the other built-in tools don't cover.

## Design Rationale

`shell` is the general escape hatch because an agent occasionally needs a real
workspace command that is not worth modeling as a dedicated tool. It uses
the local platform shell to match developer command-line ergonomics: pipelines,
redirects, environment variables, and existing scripts all work without
inventing a custom argument schema for every possible operation.

stdout and stderr are merged so diagnostics appear in the same order a terminal
would show them. Output is capped while the process pipe is being read because
commands can accidentally emit generated artifacts, dependency listings, or
compiler invocations large enough to damage the model context. When reading
proves the output exceeds the cap, the tool cancels the child process and treats
the result as a tool error so the agent knows it received only an output prefix.

Callers may also set `timeout_ms` for commands that could wait indefinitely.
When the timeout expires, the in-flight process collection is cancelled and the
tool returns an error instead of blocking the agent loop.

## API Style

Use `cwd` whenever the command is workspace-relative, and keep commands
specific:

```json
{
  "cmd": "git status --short",
  "cwd": "/Users/dii/git/openseek"
}
```

Prefer dedicated tools when they encode useful policy. For MoonBit compiler
diagnostics, use `moon_check`; for MoonBit test/run/info/fmt/build validation,
use `moon_cmd`. Use `shell` for everything else or for commands that need shell
features such as pipes.

## Arguments

| Name | Type   | Required | Notes |
| ---- | ------ | -------- | ----- |
| `cmd` | string | yes | Passed as the single command argument to the platform shell. |
| `cwd` | string | no  | Working directory. An empty string is treated as missing. |
| `timeout_ms` | number | no | Positive timeout in milliseconds. Timed-out commands are cancelled and reported as tool errors. |
| `max_output_chars` | number | no | Defaults to 12000, capped at 50000. The retained output prefix is bounded while reading; exceeding the limit cancels the command and returns a tool error. |

## Action

The action is always `Respond(ToolOutput(...))` — the agent loop forwards
`ToolOutput.content` to the model as a tool-call response and never finishes
from a `shell` invocation. `is_error` is `true` for launch failures, invalid
arguments, non-zero shell exit codes, and output truncation. The string body
has one of these shapes:

- `"exit=<code>\n<stdout/stderr merged>"` — normal completion.
- `"exit=<code-or-cancelled>\ntruncated=true\noutput_limit_reached=true\nshown_chars=<n>\nmax_output_chars=<n>\n<output-prefix>"` —
  output exceeded `max_output_chars` while the process pipe was being read. The
  command is cancelled if it has not already exited; no full output length is
  reported because the full output was intentionally not collected.
- `"error: shell command timed out after <n>ms"` — `timeout_ms` elapsed before
  the command completed.
- `"error running shell: <error>"` — the platform shell failed to launch
  (rare; usually a process subsystem error).
- `"error: shell requires arguments.cmd"` — payload was an object but had no
  `cmd` field.
- `"error: shell requires object arguments"` — payload was not a JSON object.

`stderr` is redirected into the same process output pipe as `stdout` so the
model sees the same interleaving a developer would see in a terminal.

## Example

```moonbit check
///|
test "shell tool advertises the expected schema" {
  let tool = @shell.definition()
  assert_eq(tool.name, "shell")
  assert_true(tool.description.contains("arguments.cmd"))
  let JsonSchema(schema) = tool.schema
  let text = schema.stringify()
  assert_true(text.contains("\"cmd\""))
  assert_true(text.contains("\"timeout_ms\""))
  assert_true(text.contains("\"max_output_chars\""))
  assert_true(text.contains("\"required\""))
}
```

```moonbit check
///|
async test "shell tool runs a project-style command through the registry" {
  let dir = @fs.tmpdir(prefix="openseek-shell-readme-")
  let tools = @agent_tool.Tools([@shell.definition()])
  let arguments : Json = {
    "cmd": "echo 'alpha beta'",
    "cwd": dir,
    "timeout_ms": 5000,
  }
  let call = @agent_tool.AgentToolCall(
    ToolCall(
      id="call_shell_count",
      name="shell",
      arguments=arguments.stringify(),
    ),
  )
  let result = @agent_tool.execute_tool_call(call, tools)
  @fs.rmdir(dir, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("exit=0"))
  assert_true(output.content.contains("alpha beta"))
}
```
