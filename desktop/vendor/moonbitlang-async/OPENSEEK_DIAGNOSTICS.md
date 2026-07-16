# OpenSeek async diagnostics

This directory vendors `moonbitlang/async` 0.20.1 so OpenSeek can trace a
suspected native event-loop completion-pipe failure without modifying the
registry cache. The public MoonBit API and normal runtime behavior are
unchanged when tracing is disabled.

Set `MOONBIT_ASYNC_TRACE` only for a diagnostic run. A value of `1` writes to
`/tmp/moonbit-async-<pid>.log`; any other non-empty value is used as the log
path. `0` or an unset variable disables tracing.

On macOS, launch a fresh Desktop instance with:

```sh
open -n \
  --env MOONBIT_ASYNC_TRACE=1 \
  "desktop/dist/OpenSeek Desktop.app"
```

The trace records only timestamps, sequence numbers, process/thread IDs, file
descriptors, completion integers, and system error codes. It does not record
user content, paths handled by async jobs, or network payloads.

The key events are:

- `pool_init` / `pool_destroy`: lifetime of the thread-pool notification FD.
- `sigwait_return`: the direct result of the global signal waiter.
- `completion_write`: every worker or signal value written to the pipe.
- `completion_read`: each pipe read and its byte count.
- `completion_read_high_bit`: a value that the MoonBit event loop will decode
  as a process signal. In particular, `raw=0x80000000 decoded_signal=0` leads
  to `KilledBySignal(0)` and process exit status 128.

To distinguish the remaining hypotheses, find the first
`completion_read_high_bit` line and compare preceding writes:

- A matching `source=signal` write points to the signal waiter.
- A matching `source=worker` write points to job-ID corruption or overflow.
- No matching write points to notification-FD reuse, a foreign writer, or
  corruption between the write and read sides.
