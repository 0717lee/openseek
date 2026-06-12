///|
/// Copy a finished run's durable session somewhere a data-collection effort
/// can find it, per `--upload` / `OPENSEEK_UPLOAD`:
///
/// - `""` (default): nowhere — nothing ever leaves the workspace.
/// - `"local"`: `$HOME/.openseek/sessions/<id>/`.
/// - any other value: `<dir>/sessions/<id>/` — the target works as a
///   `--session-root` for the viz server and `--session-list`.
///
/// Runs after the turn ends, success and failure alike — failed runs are
/// the diagnostically interesting ones. Strictly best-effort: a collection
/// problem must never fail the run that produced the data, so every failure
/// is logged and swallowed. Each copy gains a `meta.json` sidecar carrying
/// provenance the session format itself does not store (model, run
/// settings, source workspace, outcome, upload time).
async fn upload_session(
  matches : @argparse.Matches,
  model : @deepseek.Model,
  id : @agent_session.SessionId,
) -> Unit noraise {
  // `defer` only accepts non-raising calls, and even logging can raise, so
  // the entire collection attempt — including its failure logging — lives
  // behind one swallow-everything boundary.
  run_upload(matches, model, id) catch {
    _ => ()
  }
}

///|
async fn run_upload(
  matches : @argparse.Matches,
  model : @deepseek.Model,
  id : @agent_session.SessionId,
) -> Unit {
  let target = value(matches, "upload")
  if target == "" {
    return
  }
  upload_session_to(target, matches, model, id) catch {
    error =>
      @xlog.warn() <?
        {
          "event": "session_uploaded",
          "ok": false,
          "session": id.value(),
          "target": target,
          "error": "\{error}",
        }
  }
}

///|
async fn upload_session_to(
  target : String,
  matches : @argparse.Matches,
  model : @deepseek.Model,
  id : @agent_session.SessionId,
) -> Unit {
  let store = @store.SessionStore(session_root(matches))
  let events_path = store.event_log_file(id)
  guard @fs.exists(events_path) else {
    // Deferred first write never happened: the run failed before any event,
    // so there is no session on disk and nothing to collect.
    @xlog.info() <?
      {
        "event": "session_uploaded",
        "ok": false,
        "session": id.value(),
        "target": target,
        "error": "no durable session was written",
      }
    return
  }
  let events = @fs.read_file(events_path).text()
  let header_path = store.header_file(id)
  let header = if @fs.exists(header_path) {
    @fs.read_file(header_path).text()
  } else {
    ""
  }
  let workspace = @fs.realpath(".") catch { _ => "." }
  let meta : Json = {
    "session": id.value(),
    "model": model.to_string(),
    "thinking": value(matches, "thinking"),
    "reasoning_effort": value(matches, "reasoning-effort"),
    "max_steps": value(matches, "max-steps"),
    "workspace": workspace,
    "outcome": terminal_outcome(events),
    "uploaded_unix_ms": @env.now().reinterpret_as_int64().to_double(),
  }
  let base = if target == "local" {
    guard @env.get_env_var("HOME") is Some(home) && home != "" else {
      fail("--upload local needs HOME to locate ~/.openseek")
    }
    home + "/.openseek"
  } else {
    target
  }
  let dest = base + "/sessions/" + id.value()
  @fs.mkdir(dest, recursive=true)
  @fs.write_file(dest + "/events.jsonl", events, create_mode=CreateOrTruncate)
  if header != "" {
    @fs.write_file(dest + "/session.json", header, create_mode=CreateOrTruncate)
  }
  @fs.write_file(
    dest + "/meta.json",
    meta.stringify(),
    create_mode=CreateOrTruncate,
  )
  @xlog.info() <?
    {
      "event": "session_uploaded",
      "ok": true,
      "session": id.value(),
      "target": dest,
    }
}

///|
/// The run's terminal state as recorded in the event log — "finished",
/// "failed", or "missing" when the run ended without a terminal event (step
/// cap, crash). Scans from the end since the terminal event, when present,
/// is the last line.
fn terminal_outcome(events : String) -> String {
  let lines = events.split("\n").to_array()
  for i = lines.length() - 1; i >= 0; i = i - 1 {
    let line = lines[i].trim()
    if line.is_empty() {
      continue
    }
    let parsed = @json.parse(line.to_owned()) catch { _ => continue }
    if parsed
      is {
        "item": {
          "kind": "terminal",
          "payload": { "kind": String(kind), .. },
          ..
        },
        ..
      } {
      return kind
    }
    // The last non-empty line is not a terminal event: the run was cut off.
    return "missing"
  }
  "missing"
}

///|
test "terminal_outcome reads the last event's verdict" {
  let finished =
    #|{"sequence":1,"ts":0,"item":{"kind":"user","payload":{"content":"hi"}}}
    #|{"sequence":2,"ts":0,"item":{"kind":"terminal","payload":{"kind":"finished","message":"done"}}}
  assert_eq(terminal_outcome(finished), "finished")
  let failed =
    #|{"sequence":1,"ts":0,"item":{"kind":"terminal","payload":{"kind":"failed","message":"boom"}}}
  assert_eq(terminal_outcome(failed), "failed")
  let cut_off =
    #|{"sequence":1,"ts":0,"item":{"kind":"user","payload":{"content":"hi"}}}
  assert_eq(terminal_outcome(cut_off), "missing")
  assert_eq(terminal_outcome(""), "missing")
}
