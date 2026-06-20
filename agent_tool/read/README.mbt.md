# Read Tool

`read` returns text from a file at `arguments.path`. By default it returns whole
files when they fit within the output cap. For larger files, or when the agent
only needs a focused region, pass `start_line`, `max_lines`, or
`max_output_chars`.

When the agent needs several known independent files, prefer batching separate
single-file `read` tool calls in one assistant response. Use `arguments.paths`
only when the host cannot batch tool calls or when one shared output budget and
inline per-file errors are more useful than independent results.

Do not use `read` for directories. Inspect directories with `ls` or `tree`, then
read specific files.

## Design Rationale

`read` preserves the simple whole-file behavior for small files because that is
the most convenient path when the agent needs full context. The optional range
and output-cap arguments exist for the failure mode seen in longer evaluations:
large generated files and dependency sources can flood the transcript and push
useful context out of the model window.

Ranged or capped reads include a metadata header so the model knows what it saw
and what it did not see. The body of those headered blocks is line-numbered
(`right-aligned-number| text`) to make follow-up edits and focused reads less
error-prone.
Automatic character truncation is marked as a tool error even when the file was
read successfully; that makes lossy context visible to the loop instead of
silently pretending the returned prefix is complete.

The preferred multi-file pattern is several independent `read` calls in the
same assistant response. That avoids extra model round trips while preserving
single-file ranges and independent output budgets. `paths` remains available as
a fallback for hosts that cannot batch tool calls, or for cases where one shared
`max_output_chars` budget is desirable: every file returns as its own headered
block, a file that fails to read reports inline while the others still land
(mirroring how `moon ide doc` reports per-query misses), and the budget is
shared across the call in argument order. Headers, separators, and error blocks
count against it too, and an exhausted budget collapses the unread tail into one
bounded skipped-files marker, so output stays near the cap no matter how many
paths the call names. Line-range options stay single-file: a range only means
something against one file.

## API Style

Use `path` alone when the file is known to be small or the full file is needed:

```json
{ "path": "agent/prompt.mbt" }
```

Use `start_line` and `max_lines` for generated files, logs, or dependency
source where the agent has already identified the relevant region:

```json
{ "path": "agent/prompt.mbt", "start_line": 40, "max_lines": 80 }
```

Use `max_output_chars` to protect the transcript when file size is uncertain.
For headered reads, the cap applies after line-number gutters are rendered.
Prefer a range plus a cap over reading a large file and relying on truncation.

## Arguments

| Name | Type | Required | Notes |
| ---- | ---- | -------- | ----- |
| `path` | string | one of `path`/`paths` | Filesystem path. Relative paths resolve against the agent process's current working directory. |
| `paths` | string array | one of `path`/`paths` | Several files in one call when batching separate read calls is unavailable or a shared budget is desired; per-file errors report inline. |
| `start_line` | number | no | 1-based first line to return. Defaults to `1`. Single-file calls only. |
| `max_lines` | number | no | Maximum number of lines to return. Single-file calls only. |
| `max_output_chars` | number | no | Maximum rendered content chars to return across the call, including line-number gutters when present. Defaults to `12000` and is capped at `50000`. |

## Action

The action is always `Respond(ToolOutput(...))` — the agent loop forwards
`ToolOutput.content` to the model as a tool-call response. `is_error` is
`false` on success and `true` for read failures, argument failures, or automatic
character truncation. The string body has one of these shapes:

- The file's text contents on uncapped whole-file success.
- A metadata header followed by `---` and line-numbered selected content for
  ranged reads or capped reads. The header includes line and character counts
  plus `line_format=right-aligned-number| text`; `shown_chars` counts the
  rendered numbered body, and `truncated=true` when `max_output_chars` cut that
  rendered body.
- Headered line-numbered blocks separated by blank lines for multi-file reads. A failed
  file contributes an inline `error reading <path>: <error>` block;
  `is_error` only flips when every file failed or the shared budget
  truncated or skipped content.
- `"error reading <path>: <error>"` — a single-file read failed. Common
  causes: the file is missing, the agent doesn't have read permissions, or
  the bytes aren't valid UTF-8.
- `"error: read requires arguments.path or arguments.paths"` — payload was an
  object but named no file.
- `"error: read requires object arguments"` — payload was not a JSON object.

## Example

```moonbit check
///|
test "read tool advertises the expected schema" {
  let tool = @read.definition()
  assert_eq(tool.name, "read")
  let JsonSchema(schema) = tool.schema
  let text = schema.stringify()
  assert_true(text.contains("\"path\""))
  assert_true(text.contains("\"paths\""))
  assert_true(text.contains("\"start_line\""))
  assert_true(text.contains("\"max_lines\""))
  assert_true(text.contains("\"max_output_chars\""))
}
```

```moonbit check
///|
async test "read tool reads a workspace note through the registry" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/task.txt"
    let content = "Task: summarize test failures\nStatus: investigating\n"
    @fs.write_file(path, content, create_mode=CreateOrTruncate)

    let tools = @agent_tool.Tools([@read.definition()])
    // Stringify a JSON object so a Windows temp path (`C:\Users\...`) survives
    // round-tripping instead of becoming an invalid `\U` escape.
    let arguments : Json = { "path": path }
    let call = @agent_tool.AgentToolCall(
      ToolCall(
        id="call_read_note",
        name="read",
        arguments=arguments.stringify(),
      ),
    )
    let result = @agent_tool.execute_tool_call(call, tools)
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, content)
    assert_false(output.is_error)
  })
}
```

```moonbit check
///|
async test "read tool supports focused range reads" {
  @vfs.with_tmpdir(prefix="openseek-read-readme-", dir => {
    let path = "\{dir}/range.txt"
    @fs.write_file(
      path,
      "alpha\nbeta\ngamma\ndelta",
      create_mode=CreateOrTruncate,
    )

    let tools = @agent_tool.Tools([@read.definition()])
    let arguments : Json = { "path": path, "start_line": 2, "max_lines": 2 }
    let call = @agent_tool.AgentToolCall(
      ToolCall(
        id="call_read_range",
        name="read",
        arguments=arguments.stringify(),
      ),
    )
    let result = @agent_tool.execute_tool_call(call, tools)
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.content.contains("start_line=2"))
    assert_true(output.content.contains("shown_lines=2"))
    assert_true(output.content.contains("2| beta\n3| gamma"))
    assert_false(output.is_error)
  })
}
```
