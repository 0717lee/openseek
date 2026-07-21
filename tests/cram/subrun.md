# Verified `openseek subrun` Child-Mode Contract

These examples are executed by `moon cram test tests/cram`. They exercise the
INTERNAL child mode end to end through the real binary: one JSON input line on
stdin (the `sleep` holds the pipe open the way a parent runner does — stdin EOF
is the cancel signal), standard JSONL events on stdout, and a final
`{"subrun_report": ...}` line. The `echo` kind is modelless, so the suite needs
no API key and makes no network calls. Timestamps and source locations vary, so
they are normalized with `sed`.

## Echo Kind: Events Then the Typed Report Line

```mooncram
$ (printf '{"probe": 42}\n'; sleep 1) | openseek.exe subrun echo | sed -E 's/"timestamp":"[^"]*"/"timestamp":"T"/; s/"source":"[^"]*"/"source":"S"/'
{"timestamp":"T","level":"INFO","source":"S","event":"agent_step","step":1}
{"timestamp":"T","level":"INFO","source":"S","event":"usage","usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7}}
{"subrun_report":{"probe":42}}
```

## Failure Events Survive to the Wire

An unknown kind must deliver its `command_error` event — the parent's only
classification signal — before exiting; an early `exit()` would discard the
asynchronously drained queue.

```mooncram
$ (printf '{}\n'; sleep 1) | openseek.exe subrun nope | sed -E 's/"timestamp":"[^"]*"/"timestamp":"T"/; s/"source":"[^"]*"/"source":"S"/'
{"timestamp":"T","level":"ERROR","source":"S","event":"command_error","error":"unknown subrun kind: nope"}
```
