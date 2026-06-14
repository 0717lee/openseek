///|
async fn main {
  run_analyze(@argparse.parse(cli_command()))
}

///|
async fn run_analyze(matches : @argparse.Matches) -> Unit {
  let session = load_session(matches)
  let result = @session_analyzer.analyze_session(session)
  let out_dir = value(matches, "out").trim().to_owned()
  if out_dir != "" {
    result.write_files(out_dir)
  } else {
    match value(matches, "format") {
      "markdown" => println(result.markdown())
      "html" => println(result.html())
      "json" => println(result.to_json().stringify())
      format => fail("--format must be markdown, html, or json; got: \{format}")
    }
  }
}

///|
async fn load_session(matches : @argparse.Matches) -> @agent_session.Session {
  let events_path = value(matches, "events").trim().to_owned()
  let session_value = value(matches, "session").trim().to_owned()
  if events_path != "" {
    return load_events_session(events_path, session_value)
  }
  if session_value == "" {
    fail("--session is required when --events is not provided")
  }
  @store.SessionStore(value(matches, "session-root")).load(
    SessionId(session_value),
  )
}

///|
async fn load_events_session(
  path : String,
  session_id : String,
) -> @agent_session.Session {
  let text = @fs.read_file(path).text()
  let parsed = @session_log.parse_events(text)
  if parsed.errors.length() > 0 {
    fail("events decode errors \{parsed.errors.length()}")
  }
  @session_log.session_from_parse(
    parsed,
    id=if session_id == "" {
      session_id_from_events_path(path)
    } else {
      session_id
    },
    system_prompt="",
  )
}

///|
fn session_id_from_events_path(path : String) -> String {
  let without_file = match path.strip_suffix("/events.jsonl") {
    Some(prefix) => prefix
    None => path
  }
  match without_file.rev_find("/") {
    Some(index) if index + 1 < without_file.length() =>
      without_file[index + 1:].to_owned()
    _ => "session"
  }
}

///|
fn cli_command() -> @argparse.Command {
  Command("openseek-analyze", about="Analyze one recorded OpenSeek session.", options=[
    OptionArg(
      "events",
      long="events",
      default_values=[""],
      about="Path to one session events.jsonl file.",
    ),
    OptionArg(
      "session-root",
      long="session-root",
      env="OPENSEEK_SESSION_ROOT",
      default_values=[".openseek"],
      about="Directory containing durable OpenSeek sessions.",
    ),
    OptionArg(
      "session",
      long="session",
      default_values=[""],
      about="Session id to load, or override for --events.",
    ),
    OptionArg(
      "format",
      long="format",
      default_values=["markdown"],
      about="Output format when --out is not set: markdown, html, or json.",
    ),
    OptionArg(
      "out",
      long="out",
      default_values=[""],
      about="Directory to write report.md, report.html, and report.json.",
    ),
  ])
}

///|
fn value(matches : @argparse.Matches, name : String) -> String raise {
  match matches.values.get(name) {
    Some([value]) => value
    Some(values) if values.length() > 0 => values[0]
    _ => fail("missing parsed argument: \{name}")
  }
}
