///|
/// One JSONL line that could not be decoded into a `SessionEvent`. Kept so the
/// viewer can surface the offending line instead of silently dropping it or
/// aborting the whole load.
pub(all) struct LineError {
  line_number : Int
  content : String
  message : String
} derive(Debug)

///|
/// The result of parsing an `events.jsonl` log line by line. `events` are the
/// records that decoded cleanly (in file order); `errors` are individual lines
/// that failed to decode; `partial_tail` is true when the final line looked
/// like a half-written record from a process that exited mid-append (no
/// trailing newline and the last segment failed to decode), which the viewer
/// reports as a benign truncation rather than corruption.
pub(all) struct ParsedLog {
  events : Array[@agent_session.SessionEvent]
  errors : Array[LineError]
  partial_tail : Bool
} derive(Debug)

///|
/// Parse an `events.jsonl` log into typed `SessionEvent`s, tolerating a
/// truncated trailing line and per-line decode failures. Blank lines are
/// ignored. A decode failure on any line other than an unterminated final line
/// is recorded as a `LineError` and parsing continues, so one bad record never
/// hides the rest of the conversation.
pub fn parse_events(text : String) -> ParsedLog {
  let events : Array[@agent_session.SessionEvent] = []
  let errors : Array[LineError] = []
  let ends_with_newline = text.has_suffix("\n")
  let lines = text.split("\n").map(line => line.to_owned()).collect()
  let mut partial_tail = false
  for index, line in lines {
    let line_number = index + 1
    if line.trim().is_empty() {
      continue
    }
    let is_last_segment = index == lines.length() - 1
    let event : @agent_session.SessionEvent = @json.from_json(@json.parse(line)) catch {
      error => {
        // A failed final line with no terminating newline is the classic
        // signature of a crash between `write(line)` and `write("\n")`; treat
        // it as a truncated tail, not a corrupt record.
        if is_last_segment && !ends_with_newline {
          partial_tail = true
        } else {
          errors.push({ line_number, content: line, message: "\{error}" })
        }
        continue
      }
    }
    events.push(event)
  }
  { events, errors, partial_tail }
}

///|
/// Build an immutable `Session` from parsed events plus an optional header.
/// When the header is absent (no `session.json`), a placeholder id and an empty
/// system prompt are used so the viewer can still render the event log. The
/// header's id and system prompt win when present.
pub fn session_from_parse(
  parsed : ParsedLog,
  id~ : String,
  system_prompt~ : String,
) -> @agent_session.Session {
  let session_id : @agent_session.SessionId = SessionId(id)
  Session(session_id, system_prompt~, events=@vector.from_array(parsed.events))
}
