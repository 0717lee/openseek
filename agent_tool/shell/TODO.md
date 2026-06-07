# Shell Tool TODO

Review target: `agent_tool/shell`.

## Bugs And Risks

- [x] Add a hard `timeout_ms` option for shell commands.
  - Current behavior awaits `@process.collect_output_merged`, so a hung command blocks the whole agent loop.
  - A timeout should cancel the child process and return a tool error with elapsed time.

- [x] Enforce output limits while reading, not after full collection.
  - `max_output_chars` is enforced on the retained output prefix while the process pipe is read.
  - Commands such as `yes`, `tail -f`, or huge finite output are cancelled once the limit is reached.

- [ ] Harden MoonBit command policy bypass detection.
  - Current guard is based on simple space splitting and a few string fragments.
  - Cases to block for `moon_check`: `env FOO=x moon check`, `PATH=/usr/bin moon check`, `cd demo;moon check`, subshells, command substitutions, and other executable `moon check` tokens.

- [ ] Add tests for guarded-command bypasses.
  - Include env wrappers, empty env assignments, semicolons without spaces, newlines, subshells, and `moon test --update`.

## Missing Features

- [ ] Support separate stdout and stderr capture.
  - Current output is always merged, which weakens CLI-contract checks that need parseable stdout and clean stderr.
  - Consider returning structured sections or adding `merge_output`.

- [ ] Add structured `stdin`.
  - This avoids shell pipes and heredocs for multiline probes and non-MoonBit commands.
  - This would make shell `moon run -` probes less quoting-sensitive.

- [ ] Add optional `argv` execution mode.
  - Keep `cmd` for shell features such as pipes and redirects.
  - Use `argv` for exact execution when quoting paths, regexes, JSONPath/jq expressions, or generated arguments would be fragile.

- [ ] Echo command context in the result.
  - Include `cwd=...` and `command=...` so logs remain self-auditing.

## Nice To Have

- [ ] Consider configurable environment handling.
  - Potential fields: `env`, `inherit_env`, and possibly a denylist for sensitive values in echoed metadata.

- [x] Document the distinction between `shell` and `moon_check` in `README.mbt.md` after behavior changes.

- [ ] Re-run targeted validation after changes.
  - `moon test agent_tool/shell agent_tool/shell/internal/decode --target native`
  - `moon info && moon fmt`
