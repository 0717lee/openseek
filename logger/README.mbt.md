# Logger

This package provides a tiny native-only async JSONL logger for OpenSeek. It
wraps an `@stdio.Output` and writes one JSON object per line.

## API Shape

- `stdout()`: build a stdout logger.
- `Logger::write(record)`: write a `Map[String, Json]` as one JSONL record.

```moonbit check
///|
test "logger can be constructed" {
  let _logger = @logger.Logger(@stdio.stdout)
}
```
