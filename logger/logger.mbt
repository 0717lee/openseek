///|
pub struct Logger {
  priv output : @stdio.Output
}

///|
pub fn Logger::Logger(output : @stdio.Output) -> Logger {
  { output, }
}

///|
pub fn stdout() -> Logger {
  Logger(@stdio.stdout)
}

///|
pub async fn Logger::write(self : Logger, record : Map[String, Json]) -> Unit {
  self.output.write(Json::object(record).stringify() + "\n")
}
