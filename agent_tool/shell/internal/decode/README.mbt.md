# agent_tool/shell/internal/decode

Argument decoding for the `shell` tool, which runs a command line through the
platform shell. This package is internal to `agent_tool/shell` and owns only
argument-shape decoding — the sandbox profile, the git command policy, timeout
enforcement, and background job bookkeeping all stay in the parent package.

Nothing here inspects the command text. `cmd` is carried through as an opaque
string; deciding whether it is *allowed* to run is a separate question answered
by `agent_tool/shell/internal/git_policy` and
`agent_tool/internal/source_write_policy`.

## Arguments

| Name | Type | Required | Decoder behavior |
| --- | --- | --- | --- |
| `cmd` | string | yes | Missing, `null`, or empty raises `arguments.cmd`; non-string raises `arguments.cmd to be a string`. |
| `cwd` | string | no | Defaults to `None`. Empty is treated as absent, not as an error. |
| `timeout_ms` | number | no | Defaults to `None` (no timeout). Must be positive. |
| `max_output_chars` | number | no | Defaults to `default_max_output_chars` (`12000`), clamped to `hard_max_output_chars` (`50000`). Must be positive. |
| `run_in_background` | boolean | no | Defaults to `false`. `null` also means `false`. |

Extra fields are ignored. Non-object JSON raises `object arguments`.

```mbt check
///|
test "only `cmd` is required; everything else has a default" {
  debug_inspect(
    @decode.decode({ "cmd": "moon test --target native" }),
    content=(
      #|{
      #|  cmd: "moon test --target native",
      #|  cwd: None,
      #|  timeout_ms: None,
      #|  max_output_chars: 12000,
      #|  run_in_background: false,
      #|}
    ),
  )
}

///|
test "a fully specified invocation overrides every default" {
  debug_inspect(
    @decode.decode({
      "cmd": "moon build",
      "cwd": "/work/packages/demo",
      "timeout_ms": 60000,
      "max_output_chars": 4000,
      "run_in_background": true,
    }),
    content=(
      #|{
      #|  cmd: "moon build",
      #|  cwd: Some("/work/packages/demo"),
      #|  timeout_ms: Some(60000),
      #|  max_output_chars: 4000,
      #|  run_in_background: true,
      #|}
    ),
  )
}
```

## Empty means "absent" for `cwd`, but "error" for `cmd`

The two empty strings are treated differently, and the difference is deliberate.
An empty `cwd` names no directory, and the tool already has a sensible fallback
— the workspace root — so treating it as absent turns a harmless client quirk
into the default behavior. An empty `cmd` has no fallback: there is nothing to
run, and silently succeeding would report a command that never executed.

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
test "an empty cwd is absent; an empty cmd is an error" {
  debug_inspect(@decode.decode({ "cmd": "pwd", "cwd": "" }).cwd, content="None")
  debug_inspect(
    @decode.decode({ "cmd": "pwd", "cwd": Json::null() }).cwd,
    content="None",
  )
  inspect(decode_error_says({ "cmd": "" }, "arguments.cmd"), content="true")
  inspect(
    decode_error_says(Json::empty_object(), "arguments.cmd"),
    content="true",
  )
  inspect(
    decode_error_says({ "cmd": 7 }, "arguments.cmd to be a string"),
    content="true",
  )
  inspect(decode_error_says(Json::null(), "object arguments"), content="true")
}
```

## The output budget is clamped, not trusted

`max_output_chars` bounds captured stdout+stderr. A caller may ask for less than
the default, but not for more than `hard_max_output_chars`: the ceiling exists
so one runaway command cannot flood the conversation, and asking for more is
quietly reduced rather than rejected.

```mbt check
///|
test "an oversized budget clamps silently; a smaller one is honored" {
  inspect(@decode.default_max_output_chars, content="12000")
  inspect(@decode.hard_max_output_chars, content="50000")
  inspect(
    @decode.decode({ "cmd": "cat big.log", "max_output_chars": 999999 }).max_output_chars,
    content="50000",
  )
  inspect(
    @decode.decode({ "cmd": "cat big.log", "max_output_chars": 500 }).max_output_chars,
    content="500",
  )
}
```

`timeout_ms` gets no such treatment: it has no ceiling here, and absent means
*no timeout at all* rather than some default budget. A long-running build is a
normal thing to ask for, so bounding it is the parent tool's decision, made with
context this package does not have.

```mbt check
///|
test "non-positive numbers are errors, not clamped to a floor" {
  inspect(
    decode_error_says(
      { "cmd": "sleep 1", "timeout_ms": 0 },
      "arguments.timeout_ms to be a positive number",
    ),
    content="true",
  )
  inspect(
    decode_error_says(
      { "cmd": "echo hi", "max_output_chars": -1 },
      "arguments.max_output_chars to be a positive number",
    ),
    content="true",
  )
  inspect(
    decode_error_says(
      { "cmd": "sleep 1", "timeout_ms": "60s" },
      "arguments.timeout_ms to be a number",
    ),
    content="true",
  )
  inspect(
    decode_error_says(
      { "cmd": "echo hi", "run_in_background": "yes" },
      "arguments.run_in_background to be a boolean",
    ),
    content="true",
  )
}
```
