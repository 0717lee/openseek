# Check Daemon Tool

`check_daemon` starts, inspects, and stops session-scoped background monitor
commands. It is intended for long-running feedback loops such as
`moon check --watch --output-json`, test watchers, or review/status monitors.

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

Unlike the normal `shell` tool, `check_daemon` does not apply the MoonBit
command-blocking shell policy. It is the intended place for monitored commands
such as:

```json
{
  "action": "start",
  "name": "moon-check",
  "cmd": "moon check --watch --output-json",
  "cwd": "/path/to/project"
}
```
