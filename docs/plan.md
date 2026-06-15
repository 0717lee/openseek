# OpenSeek Plans

- [Custom API URL](plans/custom-api-url.md)

## Checkpoint: TUI Session cwd Realpath Guard

- Goal: address PR review feedback that a stored session cwd like
  `/workspace/project/../other` could pass raw string containment checks while
  spawning outside the current workspace.
- Accepted design: before accepting a stored cwd, resolve both the configured
  workspace cwd and the stored cwd with `moonbitlang/async/fs.realpath`, then
  accept only a canonical stored cwd that is the canonical workspace itself or a
  subdirectory and is a directory.
- Target surfaces: `cmd/tui/main.mbt` resume cwd selection and
  `cmd/tui/session_cwd_wbtest.mbt` regression coverage.
- API/interface diff: no public API changes expected; generated `.mbti` files
  should remain semantically unchanged.
- Open questions: none.
- Next implementation step: update `with_session_cwd` and add a test for a raw
  prefix path that canonicalizes outside the workspace.
- Validation plan: `moon check`, targeted TUI tests, `moon info`, `moon fmt`,
  and full `moon test`.
