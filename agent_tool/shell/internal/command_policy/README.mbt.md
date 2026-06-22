# Shell Command Policy

This internal package contains the command-routing policy used by the `shell`
tool before it runs `sh -c`.

The policy exists for one narrow reason: the bare tool name `moon_cmd`, typed as
a shell command, is not an executable — it should be the real `moon ...`
subcommand run through shell. Everything else, including `moon check`, runs
normally.

This package is not a security sandbox. It is a local automation guardrail for a
trusted agent. The shell tool can run arbitrary commands; this package only
rejects the `moon_cmd` tool-name typo before execution.

## Enforced Policy

`moonbit_command_policy_error(cmd)` returns `Some(message)` when the command
should be blocked by `shell`, and `None` when `shell` may continue.

The current policy blocks:

| Command shape | Reason |
| --- | --- |
| `moon_cmd ...` | `moon_cmd` is a tool name, not an executable shell command; run `moon ...` directly. |

The policy allows:

| Command shape | Reason |
| --- | --- |
| `moon check` | Type-check for compiler feedback; runs through shell like any other `moon` subcommand. |
| `moon test`, `moon run`, `moon info`, `moon fmt`, `moon build` | One-shot Moon commands run through shell. |
| `git status --short` | Non-MoonBit commands remain in shell. |
| `printf hi \| wc -c` | Shell-specific pipelines remain in shell. |

## Detection Strategy

The implementation is deliberately conservative:

- Parse the command with the internal shell policy parser.
- Reject `moon_cmd` when it is a statically visible simple command name,
  including in flat compounds such as `cd demo && moon_cmd check`.
- If parsing is too complex, keep a small fallback for the old leading
  `moon_cmd` typo case.

This is still not a security sandbox and not a full POSIX shell interpreter.
Commands whose runtime argv cannot be known statically are allowed unless they
match the narrow fallback typo check.

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
