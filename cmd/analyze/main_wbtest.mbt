///|
fn session_events(session : @agent_session.Session) -> String {
  let out = StringBuilder::new()
  for event in session.events() {
    out.write_string(event.to_json().stringify())
    out.write_char('\n')
  }
  out.to_string()
}

///|
fn sample_session(id : String) -> @agent_session.Session {
  @agent_session.Session(SessionId(id), system_prompt="")
  .append(Assistant(AssistantMessage("done")))
  .append(Terminal(Finished("ok")))
}

///|
async test "events source can infer session id from path" {
  let root = @fs.tmpdir(prefix="openseek-analyze-events-")
  let path = root + "/sessions/trial-01/events.jsonl"
  @fs.mkdir(root + "/sessions/trial-01", recursive=true)
  @fs.write_file(
    path,
    session_events(sample_session("ignored")),
    create_mode=CreateOrTruncate,
  )
  let matches = cli_command().parse(argv=["--events", path])
  let session = load_session(matches)
  assert_eq(session.id().value(), "trial-01")
  @fs.rmdir(root, recursive=true)
}

///|
async test "events source can override session id" {
  let root = @fs.tmpdir(prefix="openseek-analyze-events-id-")
  let path = root + "/events.jsonl"
  @fs.write_file(
    path,
    session_events(sample_session("ignored")),
    create_mode=CreateOrTruncate,
  )
  let matches = cli_command().parse(argv=[
    "--events", path, "--session", "chosen",
  ])
  let session = load_session(matches)
  assert_eq(session.id().value(), "chosen")
  @fs.rmdir(root, recursive=true)
}

///|
async test "session root source loads store session" {
  let root = @fs.tmpdir(prefix="openseek-analyze-store-")
  let store = @store.SessionStore(root)
  store.create(sample_session("stored"))
  let matches = cli_command().parse(argv=[
    "--session-root", root, "--session", "stored",
  ])
  let session = load_session(matches)
  assert_eq(session.id().value(), "stored")
  @fs.rmdir(root, recursive=true)
}

///|
async test "run analyze writes all report files" {
  let root = @fs.tmpdir(prefix="openseek-analyze-run-")
  let events = root + "/sessions/trial-01/events.jsonl"
  let out = root + "/report"
  @fs.mkdir(root + "/sessions/trial-01", recursive=true)
  @fs.write_file(
    events,
    session_events(sample_session("trial-01")),
    create_mode=CreateOrTruncate,
  )
  let matches = cli_command().parse(argv=["--events", events, "--out", out])
  run_analyze(matches)
  assert_true(@fs.exists(out + "/report.md"))
  assert_true(@fs.exists(out + "/report.html"))
  assert_true(@fs.exists(out + "/report.json"))
  @fs.rmdir(root, recursive=true)
}

///|
test "format defaults to markdown" {
  let matches = cli_command().parse(argv=["--session", "stored"])
  assert_eq(value(matches, "format"), "markdown")
}
