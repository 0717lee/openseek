# Check Daemon Tool

`check_daemon` starts, inspects, and stops session-scoped background monitor
commands. It is intended for long-running non-MoonBit feedback loops such as
test watchers, review polling, or status monitors. Use `moon_check` for
MoonBit compiler feedback.

The tool returns an immediate result for the original tool call. Later output
is posted to the agent runtime event queue; the agent coalesces pending daemon
updates and injects them as synthetic user messages before the next model turn.

## Arguments

| Name | Type | Required | Notes |
| --- | --- | --- | --- |
| `action` | string | yes | `start`, `status`, or `stop`. |
| `cmd` | string | start | Shell command to run as the monitor. |
| `cwd` | string | no | Working directory. Empty is treated as missing. |
| `name` | string | no | Human label shown in daemon updates. |
| `id` | string | status/stop | Daemon id returned by `start`. |
| `max_output_chars` | number | no | Latest retained output cap; default `12000`, hard cap `50000`. |
| `initial_wait_ms` | number | no | Startup wait for first output; default `500`, hard cap `5000`. |

Unlike the normal `shell` tool, `check_daemon` is designed for monitored
commands that should keep running while the agent works, such as:

```json
{
  "action": "start",
  "name": "review-status",
  "cmd": "gh pr view --json reviewDecision,statusCheckRollup",
  "cwd": "/path/to/project"
}
```
