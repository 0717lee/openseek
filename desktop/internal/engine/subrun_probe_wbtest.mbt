// Probe tests against a real record file, appended to the way a child does:
// one JSON line at a time, sometimes landing mid-line between polls.

///|
/// A probe over a fresh scratch record holding only the store's header line —
/// which the probe must read past without mistaking it for an item.
async fn fresh_record(name : String) -> SubrunProbeState {
  let root = @fs.realpath(@fs.tmpdir(prefix="openseek-subrun-probe-\{name}-"))
  let session = "parent-sr-1"
  @fsx.ensure_dir(Path("\{root}/sessions/\{session}"))
  let path = subrun_record_path(root, session)
  @fs.write_file(
    path,
    ({ "version": 1, "id": session, "system_prompt": "s" } : Json).stringify() +
    "\n",
    create_mode=CreateOrTruncate,
  )
  { path, offset: 0, carry: b"", steps: 0, activity: "" }
}

///|
/// Grow the record the way the store does: append, never rewrite.
async fn append_record(state : SubrunProbeState, text : String) -> Unit {
  let existing = @fs.read_file(state.path).text()
  @fs.write_file(state.path, existing + text, create_mode=CreateOrTruncate)
}

///|
fn item_line(kind : String, payload : Json) -> String {
  ({ "sequence": 1, "item": { "kind": kind, "payload": payload } } : Json).stringify() +
  "\n"
}

///|
fn tool_line(id : String, name : String, brief? : String) -> String {
  let payload : Json = match brief {
    Some(brief) =>
      {
        "tool_call_id": id,
        "tool_name": name,
        "content": "…",
        "is_error": false,
        "brief": brief,
      }
    None =>
      {
        "tool_call_id": id,
        "tool_name": name,
        "content": "…",
        "is_error": false,
      }
  }
  item_line("tool_result", payload)
}

///|
async test "the probe counts turns and follows the child's last tool call" {
  let state = fresh_record("basics")
  // Nothing appended past the header yet: the header is not progress.
  assert_false(state.poll())
  append_record(state, item_line("user", { "content": "the task" }))
  assert_false(state.poll())
  append_record(state, item_line("assistant", { "content": "thinking" }))
  assert_true(state.poll())
  assert_eq(state.steps, 1)
  assert_eq(state.activity, "")
  append_record(state, tool_line("c1", "read", brief="read moon.mod"))
  assert_true(state.poll())
  assert_eq(state.steps, 1)
  assert_eq(state.activity, "read moon.mod")
  // A briefless result falls back to the tool's name.
  append_record(state, tool_line("c2", "shell"))
  assert_true(state.poll())
  assert_eq(state.activity, "shell")
  // The same brief again is not news, and an idle child moves nothing.
  append_record(state, tool_line("c3", "shell"))
  assert_false(state.poll())
  assert_false(state.poll())
}

///|
async test "a poll landing mid-line waits for the rest of it" {
  let state = fresh_record("torn")
  let line = tool_line("c1", "read", brief="read agent/turn_loop.mbt")
  let cut = line.length() / 2
  append_record(state, line[:cut].to_string())
  // Half a JSON object is not news, and must not be mistaken for one.
  assert_false(state.poll())
  assert_eq(state.activity, "")
  append_record(state, line[cut:].to_string())
  assert_true(state.poll())
  assert_eq(state.activity, "read agent/turn_loop.mbt")
}

///|
async test "a rewritten record is re-read from its head" {
  let state = fresh_record("rewritten")
  append_record(state, item_line("assistant", { "content": "one" }))
  assert_true(state.poll())
  assert_eq(state.steps, 1)
  // The store's repair path can rewrite the file shorter than the probe's
  // offset; reading on from that offset would land mid-line forever.
  @fs.write_file(
    state.path,
    ({ "version": 1, "id": "parent-sr-1", "system_prompt": "s" } : Json).stringify() +
    "\n",
    create_mode=CreateOrTruncate,
  )
  // The poll notices the shrink, restarts at the head, and re-reads what is
  // left — only the header, which is not progress.
  assert_false(state.poll())
  assert_eq(state.steps, 0)
  append_record(state, item_line("assistant", { "content": "again" }))
  assert_true(state.poll())
  // Counting restarts with the record it is counting: the item that survived
  // a repair is counted once, not twice.
  assert_eq(state.steps, 1)
}

///|
async test "a record that does not exist yet is not an error" {
  let root = @fs.realpath(@fs.tmpdir(prefix="openseek-subrun-probe-missing-"))
  let state = {
    path: subrun_record_path(root, "parent-sr-9"),
    offset: 0,
    carry: b"",
    steps: 0,
    activity: "",
  }
  // The child is still starting: polls report nothing until it writes.
  assert_false(state.poll())
  assert_false(state.poll())
}
