# Shell Command Policy

This internal package contains the command-routing policy used by the `shell`
tool before it runs `sh -c`.

The policy exists for one narrow reason: iterative `moon check` feedback should
use `moon_check` instead of the general shell escape hatch. `moon_check` owns a
persistent watcher and can inject background updates into the agent loop.

This package is not a security sandbox. It is a local automation guardrail for a
trusted agent. The shell tool can still run arbitrary non-MoonBit commands, and
this package only decides whether a shell command should be rejected before
execution because it looks like `moon check`, which belongs in `moon_check`.

## Enforced Policy

`moonbit_command_policy_error(cmd)` returns `Some(message)` when the command
should be blocked by `shell`, and `None` when `shell` may continue.

The current policy blocks:

| Command shape | Reason |
| --- | --- |
| `moon check` | Use `moon_check` for persistent compiler feedback. |
| `moon_cmd ...` | `moon_cmd` is a tool name, not an executable shell command. |
| `cd dir && moon check` | Use the shell tool's `cwd` field plus `moon_check` instead of embedding `cd`. |

The policy allows:

| Command shape | Reason |
| --- | --- |
| `moon --version` | Informational `moon` invocations outside the guarded subcommands. |
| `moon test`, `moon run`, `moon info`, `moon fmt`, `moon build` | One-shot Moon commands run through shell. |
| `git status --short` | Non-MoonBit commands remain in shell. |
| `printf hi \| wc -c` | Shell-specific pipelines remain in shell unless they embed a guarded `moon` command. |

## Detection Strategy

The implementation is deliberately small and conservative for the cases it
knows about:

- Split the shell command into rough words.
- Skip simple leading environment assignments such as `DEEPSEEK_MODEL=x`.
- Reject a leading `moon_cmd`.
- Reject a leading `moon check`.
- Reject a few embedded forms such as `&& moon check`, `; moon check`, or a
  newline followed by `moon check`.

This is a heuristic parser, not a full POSIX shell parser. It is good enough to
keep common accidental bypasses from using raw shell, but it does not understand
every valid shell construct. Known hardening work is tracked in
`agent_tool/shell/TODO.md`.

## Examples

```moonbit check
///|
test "command policy blocks structured MoonBit validation commands" {
  assert_true(moonbit_command_policy_error("moon check") is Some(_))
  assert_true(moonbit_command_policy_error("moon test --update") is None)
  assert_true(
    moonbit_command_policy_error("DEEPSEEK_MODEL=x moon run cmd/main") is None,
  )
  assert_true(moonbit_command_policy_error("cd demo && moon check") is Some(_))
}
```

```moonbit check
///|
test "command policy allows non guarded shell commands" {
  assert_true(moonbit_command_policy_error("moon --version") is None)
  assert_true(moonbit_command_policy_error("git status --short") is None)
  assert_true(moonbit_command_policy_error("printf hi | wc -c") is None)
}
```

## Operational Guidance

When this policy blocks a command, the caller should not try to quote around it
or rewrite it as a more complex shell string. Use:

- `moon_check` for persistent
  `moon check --watch --diagnostic-limit 10` diagnostics.
- Shell for one-shot commands such as `moon test`, `moon run`, `moon info`,
  `moon fmt`, `moon build`, `moon update`, `moon add`, and `moon remove`.
- The shell tool's `cwd` field instead of `cd ... &&`.
- Ordinary shell pipes or heredocs for `moon run` stdin probes.
