///|
let runtime_metadata_keys : Array[String] = [
  "events", "id", "key", "cwd", "command", "status", "seq", "exit", "truncated",
  "max_output_chars", "restart_count", "restart_limit", "restart_reason",
]

///|
/// Whether this durable runtime notice is text the engine wrote for the
/// model rather than news for the reader: the goal family (markers, the
/// baseline pairing record, reminders, checks) and the plan cadence's
/// turn-boundary reminder.
///
/// The live event path already drops these — `decode_engine_event` has no
/// `plan_reminder` case — and the durable path has to agree, or the same
/// text surfaces here as a bogus `moon_check` card: `parse_runtime_update`
/// classifies every line it does not recognize as metadata as a diagnostic,
/// so any prose at all clears the render threshold.
///
/// Local prefix check: this js-only package cannot depend on
/// `agent_session`'s constants.
fn is_model_directed_notice(content : String) -> Bool {
  content.has_prefix("[goal") || content.has_prefix("[plan reminder]")
}

///|
/// Split a `runtime_update` notice (the engine's `moon_check --watch`
/// stream) into the watcher status and the diagnostic lines, dropping the
/// metadata assignments the engine prepends.
pub fn parse_runtime_update(content : String) -> RuntimeUpdateView {
  let mut status : String? = None
  let diagnostics : Array[String] = []
  for raw in content.split("\n") {
    let line = raw.to_owned()
    if line == "[moon_check update]" {
      continue
    }
    let is_metadata = if line.split_once("=") is Some((key, value)) {
      let key = key.to_owned()
      if runtime_metadata_keys.contains(key) {
        if key == "status" {
          // `status=` with nothing after it names no state. It still counts
          // as metadata — the line is not a diagnostic — but it must not
          // become a chip reading "moon_check " with a blank status.
          let value = value.trim().to_owned()
          status = if value.is_empty() { None } else { Some(value) }
        }
        true
      } else {
        false
      }
    } else {
      false
    }
    if !is_metadata {
      diagnostics.push(line)
    }
  }
  { status, diagnostics }
}

///|
fn runtime_update_title(update : RuntimeUpdateView) -> String {
  match update.status {
    Some(status) => "moon_check \{status}"
    None => "moon_check"
  }
}

///|
test "parse runtime update strips moon_check metadata" {
  let update = parse_runtime_update(
    "[moon_check update]\nevents=3\nid=moon-check-1\ncwd=.\ncommand=moon check --watch --diagnostic-limit 10\nstatus=running\nseq=3\nWarning: unused variable x\nFinished.",
  )
  assert_eq(update.status, Some("running"))
  inspect(
    update.diagnostics.join("|"),
    content="Warning: unused variable x|Finished.",
  )
}

///|
test "a blank status assignment names no watcher state" {
  let update = parse_runtime_update("[moon_check update]\nstatus=\nFinished.")
  assert_eq(update.status, None)
  inspect(update.diagnostics.join("|"), content="Finished.")
}

///|
test "parse runtime update keeps diagnostic assignment lines" {
  let update = parse_runtime_update(
    "[moon_check update]\nstatus=running\nlet buf = Buffer()\nFinished.",
  )
  assert_eq(update.status, Some("running"))
  inspect(update.diagnostics.join("|"), content="let buf = Buffer()|Finished.")
}
