# agent_tool/read/internal/decode

Argument decoding for the `read` tool, which returns a window of one file's
contents. This package is internal to `agent_tool/read` and owns only
argument-shape decoding; opening the file, numbering lines, and rendering the
window stay in the parent package.

## Arguments

| Name | Type | Required | Decoder behavior |
| --- | --- | --- | --- |
| `path` | string | yes | Missing or `null` raises `arguments.path`; empty raises `arguments.path to be a non-empty string`; non-string raises `arguments.path to be a string`. |
| `start_line` | number | no | 1-based, defaults to `1`. Must be positive. |
| `max_lines` | number | no | Defaults to unbounded (`None`). Must be positive. |
| `max_output_chars` | number | no | Defaults to `12000`, clamped to `hard_max_output_chars` (`50000`). Must be positive. |
| `paths` | — | — | Explicitly rejected. See below. |

Extra fields are ignored. Non-object JSON raises `object arguments`.

```mbt check
///|
test "only `path` is required; everything else has a default" {
  debug_inspect(
    @decode.decode({ "path": "agent_tool/read/read.mbt" }),
    content=(
      #|{
      #|  path: "agent_tool/read/read.mbt",
      #|  start_line: 1,
      #|  max_lines: None,
      #|  max_output_chars: 12000,
      #|}
    ),
  )
}

///|
test "an explicit window overrides every default" {
  debug_inspect(
    @decode.decode({
      "path": "agent_tool/read/read.mbt",
      "start_line": 40,
      "max_lines": 25,
      "max_output_chars": 4000,
    }),
    content=(
      #|{
      #|  path: "agent_tool/read/read.mbt",
      #|  start_line: 40,
      #|  max_lines: Some(25),
      #|  max_output_chars: 4000,
      #|}
    ),
  )
}
```

## `paths` is rejected with an explanation, not ignored

Models reach for a batch form — `paths: [...]` — because most file APIs have
one. `read` deliberately does not, and silently ignoring the field would return
one file's contents in answer to a request for several, which the model has no
way to notice.

So the field is a hard error, and the message says what to do instead: issue
several `read` calls in a single assistant response, which is already parallel.

```mbt check
///|
/// True when decoding `arguments` fails with a message containing `expected`.
/// The raw error also carries `fail`'s source location, which is why the test
/// matches on a substring rather than snapshotting the whole string.
fn decode_error_says(arguments : Json, expected : String) -> Bool {
  try {
    ignore(@decode.decode(arguments))
    false
  } catch {
    err => "\{err}".contains(expected)
  }
}

///|
test "the batch-read mistake gets an actionable message" {
  inspect(
    decode_error_says(
      { "path": "a.mbt", "paths": ["a.mbt", "b.mbt"] },
      "arguments.paths is not supported; batch separate read calls in one assistant response",
    ),
    content="true",
  )
  // Rejected even when it is the only field, and checked before `path`.
  inspect(
    decode_error_says(
      { "paths": ["a.mbt"] },
      "arguments.paths is not supported",
    ),
    content="true",
  )
  // An explicitly-null `paths` is treated as absent, so a client that
  // serializes unset optional fields still works.
  debug_inspect(
    @decode.decode({ "path": "a.mbt", "paths": Json::null() }),
    content=(
      #|{
      #|  path: "a.mbt",
      #|  start_line: 1,
      #|  max_lines: None,
      #|  max_output_chars: 12000,
      #|}
    ),
  )
}
```

## The output budget is clamped, not trusted

`max_output_chars` bounds the rendered result in UTF-16 code units. A caller may
ask for less than the default, but not for more than `hard_max_output_chars`:
the ceiling exists so one `read` cannot flood the conversation, and a model that
asks for a million characters gets `50000` rather than an error.

```mbt check
///|
test "an oversized budget clamps silently; a smaller one is honored" {
  inspect(@decode.hard_max_output_chars, content="50000")
  inspect(
    @decode.decode({ "path": "a.mbt", "max_output_chars": 999999 }).max_output_chars,
    content="50000",
  )
  inspect(
    @decode.decode({ "path": "a.mbt", "max_output_chars": 500 }).max_output_chars,
    content="500",
  )
}
```

The clamp is the only silent adjustment. Zero and negative values are rejected
rather than clamped, because they express an intent the tool cannot satisfy —
reading no lines is not a useful read, and it is more likely a bug in the
caller's arithmetic than a deliberate request.

```mbt check
///|
test "non-positive numbers are errors, not clamped to a floor" {
  inspect(
    decode_error_says(
      { "path": "a.mbt", "start_line": 0 },
      "arguments.start_line to be a positive number",
    ),
    content="true",
  )
  inspect(
    decode_error_says(
      { "path": "a.mbt", "max_lines": -1 },
      "arguments.max_lines to be a positive number",
    ),
    content="true",
  )
  inspect(
    decode_error_says(
      { "path": "a.mbt", "max_output_chars": 0 },
      "arguments.max_output_chars to be a positive number",
    ),
    content="true",
  )
  // A number of the wrong JSON type names the field too.
  inspect(
    decode_error_says(
      { "path": "a.mbt", "start_line": "40" },
      "arguments.start_line to be a number",
    ),
    content="true",
  )
}
```

## Missing versus empty `path`

Both are errors, and they are distinguished, because they are different
mistakes: an absent `path` means the model forgot the argument, while `""` means
it computed one and got nothing.

```mbt check
///|
test "absent and empty paths report differently" {
  inspect(
    decode_error_says(Json::empty_object(), "arguments.path"),
    content="true",
  )
  inspect(
    decode_error_says({ "path": "" }, "arguments.path to be a non-empty string"),
    content="true",
  )
  inspect(
    decode_error_says({ "path": 7 }, "arguments.path to be a string"),
    content="true",
  )
  inspect(decode_error_says(Json::null(), "object arguments"), content="true")
}
```
