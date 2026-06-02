# Logger

This package provides a tiny native-only async logger for OpenSeek. It wraps an
`@stdio.Output`, applies a minimum severity level, and writes JSONL records.

## API Shape

- `Level`: `TRACE`, `DEBUG`, `INFO`, `WARN`, and `ERROR`.
- `stdout(min_level?)`: build a stdout logger.
- `Logger::at(level)`: get `Some(LogSink)` when `level` is enabled, otherwise
  `None`.
- `LogSink::write_object(fields)`: write one JSON object line.

```moonbit check
///|
test "logger filters by severity" {
  let logger = @logger.Logger(@stdio.stdout, min_level=WARN)
  assert_false(logger.enabled(INFO))
  assert_true(logger.enabled(ERROR))
  assert_true(logger.at(DEBUG) is None)
  assert_true(logger.at(ERROR) is Some(_))
}
```
