# Edit Decode

`bobzhang/openseek/agent_tool/edit/internal/decode` converts raw JSON tool
arguments into the typed `EditInput` record consumed by the `edit` tool.

This package is internal to `agent_tool/edit`. It owns only argument-shape
decoding: it checks that required fields are present with the expected JSON
types, supplies the default `replace_all=false`, and raises focused error
messages for malformed payloads. Filesystem access and edit semantics stay in
the parent `edit` package.

## API Shape

- `EditInput(path, old_string, new_string, replace_all)`: the normalized edit
  request.
- `decode(arguments)`: accepts a JSON object and returns `EditInput`, or raises
  when required fields are missing or have invalid types.

## Arguments

| Name | Type | Required | Decoder behavior |
| --- | --- | --- | --- |
| `path` | string | yes | Missing or non-string values raise `arguments.path`. |
| `old_string` | string | yes | Missing or non-string values raise `arguments.old_string`. |
| `new_string` | string | yes | Missing or non-string values raise `arguments.new_string`. |
| `replace_all` | boolean | no | Defaults to `false`; non-boolean values raise `arguments.replace_all to be a boolean`. |

Extra fields are ignored. Non-object JSON values raise `object arguments`.

The decoder does not reject empty `old_string`, identical replacements, missing
files, ambiguous matches, or manifest edits. Those checks require file contents
or tool policy and are handled by `agent_tool/edit`.

## Example

```moonbit check
///|
test "decode edit input from tool arguments" {
  let focused = @decode.decode({
    "path": "agent_tool/edit/edit.mbt",
    "old_string": "Replace exact text",
    "new_string": "Replace one exact text span",
  })
  assert_eq(focused.path, "agent_tool/edit/edit.mbt")
  assert_eq(focused.old_string, "Replace exact text")
  assert_eq(focused.new_string, "Replace one exact text span")
  assert_false(focused.replace_all)

  let broad = @decode.decode({
    "path": "agent_tool/edit/README.mbt.md",
    "old_string": "moon.mod.json",
    "new_string": "moon.mod",
    "replace_all": true,
  })
  assert_true(broad.replace_all)
}
```
