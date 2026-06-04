# Shell Tool TODO

Review target: `agent_tool/shell`.

## Bugs And Risks

- [x] Add a hard `timeout_ms` option for shell commands.
  - Current behavior awaits `@process.collect_output_merged`, so a hung command blocks the whole agent loop.
  - A timeout should cancel the child process and return a tool error with elapsed time.

- [ ] Enforce output limits while reading, not after full collection.
  - Current `max_output_chars` caps only after the whole process output has been collected.
  - Commands such as `yes`, `tail -f`, or huge finite output can still hang or allocate too much before truncation.

- [ ] Harden MoonBit command policy bypass detection.
  - Current guard is based on simple space splitting and a few string fragments.
  - Cases to block or route through `moon_cmd`: `env FOO=x moon test`, `PATH=/usr/bin moon check`, `FOO= moon run`, `cd demo;moon test`, subshells, command substitutions, and other executable `moon` tokens.

- [ ] Add tests for guarded-command bypasses.
  - Include env wrappers, empty env assignments, semicolons without spaces, newlines, subshells, and `moon test --update`.

## Missing Features

- [ ] Support separate stdout and stderr capture.
  - Current output is always merged, which weakens CLI-contract checks that need parseable stdout and clean stderr.
  - Consider returning structured sections or adding `merge_output`.

- [ ] Add structured `stdin`.
  - This avoids shell pipes and heredocs for multiline probes and non-MoonBit commands.
  - `moon_cmd` already has a working pattern for stdin redirection.

- [ ] Add optional `argv` execution mode.
  - Keep `cmd` for shell features such as pipes and redirects.
  - Use `argv` for exact execution when quoting paths, regexes, JSONPath/jq expressions, or generated arguments would be fragile.

- [ ] Echo command context in the result.
  - Include `cwd=...` and `command=...` like `moon_cmd` so logs remain self-auditing.

## Nice To Have

- [ ] Consider configurable environment handling.
  - Potential fields: `env`, `inherit_env`, and possibly a denylist for sensitive values in echoed metadata.

- [ ] Document the distinction between `shell`, `moon_cmd`, and `moon_check` in `README.mbt.md` after behavior changes.

- [ ] Re-run targeted validation after changes.
  - `moon test agent_tool/shell agent_tool/shell/internal/decode --target native`
  - `moon info && moon fmt`
