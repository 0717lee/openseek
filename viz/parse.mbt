///|
/// Parse a session file (header line plus event lines) into typed
/// `SessionEvent`s, tolerating a truncated trailing line and per-line decode
/// failures. A header-less bare event log still parses with `header=None`.
pub fn parse_events(text : String) -> @session_log.ParsedLog {
  @session_log.parse_events(text)
}

///|
/// Build an immutable `Session` from parsed events plus an optional header.
/// When no header record was found on the first line, pass a placeholder id
/// and an empty system prompt so the viewer can still render the event log.
pub fn session_from_parse(
  parsed : @session_log.ParsedLog,
  id~ : String,
  system_prompt~ : String,
) -> @agent_session.Session {
  @session_log.session_from_parse(parsed, id~, system_prompt~)
}
