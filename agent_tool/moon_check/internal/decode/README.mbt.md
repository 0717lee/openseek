# Moon Check Decode

`bobzhang/openseek/agent_tool/moon_check/internal/decode` converts raw JSON tool
arguments into the typed `MoonCheckInput` record consumed by the `moon_check`
tool.

This package is internal to `agent_tool/moon_check`. It owns only argument-shape
decoding: it checks each optional field has the expected JSON type, treats
empty strings and `null` as absent, validates `target` against the moon target
whitelist, and raises focused error messages for malformed payloads. Watcher
state, process spawning, and the `moon check --watch` lifecycle stay in the
parent `moon_check` package.

## API Shape

- `MoonCheckInput(cwd, target, warn_list, deny_warn, fmt, explain)`: the
  normalized check request. All fields are optional — `cwd`, `target`, and
  `warn_list` carry `None` when omitted; the booleans default to `false`.
- `decode(arguments)`: accepts a JSON object and returns `MoonCheckInput`, or
  raises when fields have invalid types or when `target` is not in the
  supported set.

## Arguments

| Name | Type | Required | Decoder behavior |
| --- | --- | --- | --- |
| `cwd` | string | no | Empty string and `null` are treated as missing; non-string values raise `arguments.cwd to be a string`. |
| `target` | string | no | Must be one of `wasm`, `wasm-gc`, `js`, `native`, `llvm`, `all`; other strings raise `arguments.target to be one of ...`. Empty and `null` are treated as missing. |
| `warn_list` | string | no | Forwarded verbatim as `--warn-list`. Empty and `null` are treated as missing; non-string values raise `arguments.warn_list to be a string`. |
| `deny_warn` | boolean | no | Defaults to `false`; `null` is treated as `false`; non-boolean values raise `arguments.deny_warn to be a boolean`. |
| `fmt` | boolean | no | Same shape as `deny_warn`. |
| `explain` | boolean | no | Same shape as `deny_warn`. |

Extra fields are ignored. Non-object JSON values raise `object arguments`.

The decoder does not check that `cwd` points at a real workspace, that the
workspace has a `moon.mod`, or that the resulting `moon check` command would
succeed. Those checks happen when the parent `moon_check` package spawns the
watcher and observes its output.

## Example

```moonbit check
///|
test "decode moon_check input from tool arguments" {
  let focused = @decode.decode({
    "cwd": "/tmp/example_project",
    "target": "native",
    "warn_list": "+unnecessary_annotation",
    "deny_warn": true,
    "fmt": true,
    "explain": true,
  })
  assert_true(focused.cwd is Some("/tmp/example_project"))
  assert_true(focused.target is Some("native"))
  assert_true(focused.warn_list is Some("+unnecessary_annotation"))
  assert_true(focused.deny_warn)
  assert_true(focused.fmt)
  assert_true(focused.explain)

  let minimal = @decode.decode({ "cwd": "", "deny_warn": false, "fmt": null })
  assert_true(minimal.cwd is None)
  assert_true(minimal.target is None)
  assert_false(minimal.deny_warn)
  assert_false(minimal.fmt)
}
```
