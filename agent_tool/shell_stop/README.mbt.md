# Shell Stop Tool

`shell_stop` cancels a running background shell job by its `job_id` — the id
returned by `shell` with `run_in_background=true`, or by a foreground command
that was moved to the background when it outlived its `timeout_ms`.

Stopping is a request against the shared `ShellExecution`: the child process is
cancelled and the job lands on the `Stopped` status, which `shell_output`
reports as a tool error thereafter. Stopping an already-finished job is a
no-op error (`no background job with id …` covers unknown ids).

## Design Rationale

- **A requested stop produces no completion notice.** The push-completion
  watcher only announces jobs that end on their own (natural exit, or the
  output-limit watchdog); the model that called `shell_stop` already has the
  acknowledgment in the tool result, so a notice would be noise.
- **Cancellation reaches the direct child only.** The process library exposes
  no process-group kill, so a command that daemonized its own children can
  leave descendants running after the job is reported stopped — the same
  limitation as foreground cancellation, documented rather than hidden.
- Session teardown stops all jobs the same way: every child is spawned on the
  session task group, so nothing outlives the session.
