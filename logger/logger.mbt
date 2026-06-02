///|
/// Logging severity. Higher levels include fewer records when used as a
/// logger's `min_level`.
pub(all) enum Level {
  TRACE
  DEBUG
  INFO
  WARN
  ERROR
}

///|
pub fn Level::rank(self : Level) -> Int {
  match self {
    TRACE => 0
    DEBUG => 1
    INFO => 2
    WARN => 3
    ERROR => 4
  }
}

///|
pub fn Level::label(self : Level) -> String {
  match self {
    TRACE => "TRACE"
    DEBUG => "DEBUG"
    INFO => "INFO"
    WARN => "WARN"
    ERROR => "ERROR"
  }
}

///|
pub struct Logger {
  priv output : @stdio.Output
  priv min_level : Level
}

///|
pub fn Logger::Logger(
  output : @stdio.Output,
  min_level? : Level = INFO,
) -> Logger {
  { output, min_level }
}

///|
pub fn stdout(min_level? : Level = INFO) -> Logger {
  Logger(@stdio.stdout, min_level~)
}

///|
pub fn Logger::enabled(self : Logger, level : Level) -> Bool {
  level.rank() >= self.min_level.rank()
}

///|
pub fn Logger::at(self : Logger, level : Level) -> LogSink? {
  if self.enabled(level) {
    Some({ output: self.output })
  } else {
    None
  }
}

///|
pub struct LogSink {
  priv output : @stdio.Output
}

///|
pub async fn LogSink::write_object(
  self : LogSink,
  fields : Map[String, Json],
) -> Unit {
  self.output.write(Json::object(fields).stringify() + "\n")
}

///|
test "level ranks follow severity order" {
  assert_true(TRACE.rank() < DEBUG.rank())
  assert_true(DEBUG.rank() < INFO.rank())
  assert_true(INFO.rank() < WARN.rank())
  assert_true(WARN.rank() < ERROR.rank())
}

///|
test "level labels are uppercase" {
  assert_eq(TRACE.label(), "TRACE")
  assert_eq(DEBUG.label(), "DEBUG")
  assert_eq(INFO.label(), "INFO")
  assert_eq(WARN.label(), "WARN")
  assert_eq(ERROR.label(), "ERROR")
}

///|
test "logger filters below the minimum level" {
  let logger = Logger(@stdio.stdout, min_level=WARN)
  assert_false(logger.enabled(TRACE))
  assert_false(logger.enabled(DEBUG))
  assert_false(logger.enabled(INFO))
  assert_true(logger.enabled(WARN))
  assert_true(logger.enabled(ERROR))
  assert_true(logger.at(INFO) is None)
  assert_true(logger.at(ERROR) is Some(_))
}

///|
test "logger returns optional sinks by level" {
  let logger = Logger(@stdio.stdout, min_level=INFO)
  assert_true(logger.at(DEBUG) is None)
  assert_true(logger.at(INFO) is Some(_))
}
