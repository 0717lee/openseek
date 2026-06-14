///|
/// Parse an `events.jsonl` log into typed `SessionEvent`s, tolerating a
/// truncated trailing line and per-line decode failures.
pub fn parse_events(text : String) -> @session_log.ParsedLog {
  @session_log.parse_events(text)
}

///|
/// Build an immutable `Session` from parsed events plus an optional header.
/// When the header is absent (no `session.json`), a placeholder id and an empty
/// system prompt are used so the viewer can still render the event log. The
/// header's id and system prompt win when present.
pub fn session_from_parse(
  parsed : @session_log.ParsedLog,
  id~ : String,
  system_prompt~ : String,
) -> @agent_session.Session {
  @session_log.session_from_parse(parsed, id~, system_prompt~)
}
