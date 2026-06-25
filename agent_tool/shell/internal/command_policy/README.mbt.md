# Shell Command Policy

This internal package contains the command-routing policy used by the `shell`
tool before it runs `sh -c`.

The policy redirects two command shapes that an agent should not run through
shell:

- the bare tool name `moon_cmd`, typed as a shell command — it is not an
  executable and should be the real `moon ...` subcommand run through shell;
- `sed -i` (in-place file editing) — it silently misapplies edits often enough
  to be untrustworthy, so the agent is sent to the `edit`/`write` tools.

Everything else, including `moon check` and read-only `sed` (`sed -n '1,5p'`,
`... | sed s/a/b/`), runs normally.

This package is not a security sandbox. It is a local automation guardrail for a
trusted agent. The shell tool can run arbitrary commands; this package only
redirects the `moon_cmd` typo and `sed -i` editing before execution.

## Enforced Policy

`moonbit_command_policy_error(cmd)` returns `Some(message)` when the command
should be blocked by `shell`, and `None` when `shell` may continue.

The current policy blocks:

| Command shape | Reason |
| --- | --- |
| `moon_cmd ...` | `moon_cmd` is a tool name, not an executable shell command; run `moon ...` directly. |
| `sed -i ...` (incl. `--in-place`, `-i.bak`, `-Ei`) | In-place file editing is unreliable; use the `edit` tool to change contents or `write` to replace a file. |

The policy allows:

| Command shape | Reason |
| --- | --- |
| `moon check` | Type-check for compiler feedback; runs through shell like any other `moon` subcommand. |
| `moon test`, `moon run`, `moon info`, `moon fmt`, `moon build` | One-shot Moon commands run through shell. |
| `sed -n '1,5p' f`, `... \| sed s/a/b/` | Read-only `sed` (no in-place flag) remains in shell. |
| `git status --short` | Non-MoonBit commands remain in shell. |
| `printf hi \| wc -c` | Shell-specific pipelines remain in shell. |

## Detection Strategy

The implementation is deliberately conservative:

- Parse the command with the internal shell policy parser.
- Reject `moon_cmd` when it is a statically visible simple command name,
  including in flat compounds such as `cd demo && moon_cmd check`.
- Reject `sed` carrying an in-place flag when it is a statically visible simple
  command (after any `env`/`command`/`builtin` wrapper). The in-place flag is
  read off `sed`'s own arguments, so an unrelated `-i` such as `grep -i sed` or
  `env -i sed ...` does not trip it.
- If the structured parse fails (globs, expansions — e.g.
  `sed -i 's/a/b/' *.mbt`), fall back to a **rough, quote-unaware** text scan:
  split on `&&`/`||`/`&`/`;`/`|` and flag a segment whose leading command word is
  `moon_cmd`, or `sed` (any path) carrying an in-place flag. The scan is skipped
  for here-documents, whose body is data the agent is writing, not commands.

This is still not a security sandbox and not a full POSIX shell interpreter. Both
paths prefer **no false positives** (never block a command that is not actually
an in-place edit) over exhaustive recall. Known gaps that are therefore *allowed*
to run:

- `sed` that is not a command's leading word — `find ... -exec sed -i`,
  `xargs sed -i`;
- `sed -i` behind an `env` option the parser does not unwrap, e.g.
  `env -u FOO sed -i ...` (`command_name()` stays `env`); fixing this belongs in
  the shared `shell_parse` env-unwrapping and is left for a follow-up;
- in a too-complex parse, `sed -i` reached only through a `command`/`builtin`
  wrapper, or operators/env values hidden inside quotes that the quote-unaware
  split mis-segments.

The structural reason the glob cases need the rough fallback at all is that an
unquoted glob makes the whole command `TooComplex`; the deeper fix is to teach
the lexer to treat an unquoted glob as an opaque word (so the command name and
flags stay statically visible and the precise path handles them) — a shared-parser
change left for a separate PR.

## Examples

```moonbit check
///|
test "command policy allows moon subcommands through shell" {
  assert_true(
    @command_policy.moonbit_command_policy_error("moon check") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("cd demo && moon check")
    is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("moon test --update") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error(
      "DEEPSEEK_MODEL=x moon run cmd/main",
    )
    is None,
  )
}
```

```moonbit check
///|
test "command policy redirects the moon_cmd tool name" {
  guard @command_policy.moonbit_command_policy_error("moon_cmd check")
    is Some(message) else {
    fail("expected moon_cmd to be redirected")
  }
  assert_true(message.contains("moon_cmd is not a shell command"))
  assert_true(
    @command_policy.moonbit_command_policy_error("git status --short") is None,
  )
}
```

## Operational Guidance

Run `moon check` through `shell` for compiler feedback — it is much faster than
`moon build` or `moon test` (it skips code generation). Also use shell for
one-shot commands such as `moon test`, `moon run`, `moon info`, `moon fmt`,
`moon build`, `moon update`, `moon add`, and `moon remove`, and the shell tool's
`cwd` field instead of `cd ... &&`.
