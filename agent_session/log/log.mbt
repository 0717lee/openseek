///|
/// The version of the session-file header record this package understands.
let session_file_version : Int = 1

///|
/// The header record on the first line of a session file: the session identity
/// and system prompt for the event lines that follow. The system prompt lives
/// only here — it is a `Session` field, not an event — so a session file is
/// self-contained.
pub(all) struct SessionFileHeader {
  id : String
  system_prompt : String
} derive(Debug)

///|
/// Encode a header record as the JSON stored on a session file's first line.
///
/// The shape is `{ "version": 1, "id": <id>, "system_prompt": <text> }`.
pub impl ToJson for SessionFileHeader with fn to_json(
  header : SessionFileHeader,
) -> Json {
  {
    "version": session_file_version,
    "id": header.id,
    "system_prompt": header.system_prompt,
  }
}

///|
/// How a would-be header record classified. `UnsupportedVersion` is kept
/// distinct from `NotHeader` so a reader confronted with a file written by a
/// newer format can say so, instead of misreporting it as a file that has no
/// header at all.
pub(all) enum HeaderParse {
  Header(SessionFileHeader)
  UnsupportedVersion(Int)
  NotHeader
} derive(Debug)

///|
/// Classify `json` as a session-file header record.
///
/// Header and event records are structurally disjoint (events carry
/// `sequence`/`item`, never `version`), so this is also how a reader tells
/// the two apart. Any object carrying a numeric `version` other than 1 is a
/// header from a format this build does not read — `UnsupportedVersion` —
/// even though its remaining fields cannot be interpreted.
pub fn classify_header(json : Json) -> HeaderParse {
  match json {
    { "version": Number(version, ..), .. } if version.to_int() !=
      session_file_version => UnsupportedVersion(version.to_int())
    {
      "version": Number(_, ..),
      "id": String(id),
      "system_prompt": String(system_prompt),
      ..
    } => Header({ id, system_prompt })
    _ => NotHeader
  }
}

///|
/// Decode a session-file header record, or `None` when `json` is not a
/// header this build can read. Use `classify_header` to distinguish an
/// unsupported version from a non-header.
fn parse_header(json : Json) -> SessionFileHeader? {
  match classify_header(json) {
    Header(header) => Some(header)
    UnsupportedVersion(_) | NotHeader => None
  }
}

///|
/// One JSONL line that could not be decoded into a `SessionEvent`. Kept so
/// downstream tools can surface the offending line instead of silently
/// dropping it or aborting the whole load.
pub(all) struct LineError {
  line_number : Int
  content : String
  message : String
} derive(Debug)

///|
/// The result of parsing a session file line by line. `header` is the
/// identity record found on the first content line, when present; `events`
/// are the records that decoded cleanly (in file order); `errors` are
/// individual lines that failed to decode; `partial_tail` is true when the
/// final line looked like a half-written record from a process that exited
/// mid-append.
pub(all) struct ParsedLog {
  header : SessionFileHeader?
  events : Array[@agent_session.SessionEvent]
  errors : Array[LineError]
  partial_tail : Bool
} derive(Debug)

///|
/// Parse a session file into a header record and typed `SessionEvent`s,
/// tolerating a truncated trailing line and per-line decode failures. Blank
/// lines are ignored. The first content line is read as the header when it is
/// one; a header-less text (a bare event log) still parses with
/// `header=None`. A decode failure on any line other than an unterminated
/// final line is recorded as a `LineError` and parsing continues.
pub fn parse_events(text : String) -> ParsedLog {
  let mut header : SessionFileHeader? = None
  let events : Array[@agent_session.SessionEvent] = []
  let errors : Array[LineError] = []
  let ends_with_newline = text.has_suffix("\n")
  let lines = text.split("\n").map(line => line.to_owned()).collect()
  let mut partial_tail = false
  // The one policy for a line that does not decode: an unterminated final
  // line is a torn tail; anything else is a recorded per-line error.
  fn note_bad_line(
    line_number : Int,
    line : String,
    torn : Bool,
    message : String,
  ) -> Unit {
    if torn {
      partial_tail = true
    } else {
      errors.push({ line_number, content: line, message })
    }
  }

  let mut first_content_line = true
  for index, line in lines {
    let line_number = index + 1
    if line.trim().is_empty() {
      continue
    }
    let may_be_header = first_content_line
    first_content_line = false
    let torn = index == lines.length() - 1 && !ends_with_newline
    let json = @json.parse(line) catch {
      error => {
        note_bad_line(line_number, line, torn, "\{error}")
        continue
      }
    }
    if may_be_header && parse_header(json) is Some(parsed_header) {
      header = Some(parsed_header)
      continue
    }
    let event : @agent_session.SessionEvent = @json.from_json(json) catch {
      error => {
        note_bad_line(line_number, line, torn, "\{error}")
        continue
      }
    }
    events.push(event)
  }
  { header, events, errors, partial_tail }
}

///|
/// Build an immutable `Session` from parsed events plus the header values the
/// caller wants to use. When no header record is available, pass a
/// placeholder id and an empty system prompt.
pub fn session_from_parse(
  parsed : ParsedLog,
  id~ : String,
  system_prompt~ : String,
) -> @agent_session.Session {
  let session_id : @agent_session.SessionId = SessionId(id)
  Session(session_id, system_prompt~, events=@vector.from_array(parsed.events))
}
