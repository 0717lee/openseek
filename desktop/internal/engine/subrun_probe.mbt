// Live progress for a running sub-run, read from the child's own durable
// record.
//
// A sub-run (`explore`, `review`, `subtask`) runs in a process the host does
// not manage: its events go to ITS parent engine's stdin/stdout, and all the
// host ever sees are the `subrun_started` / `subrun_finished` brackets around
// a tool call that can last forty-five minutes. In between, nothing moves on
// screen.
//
// What the child DOES leave where the host can reach it is its transcript:
// when the parent session is durable, the child appends its own record at
// `<parent>-sr-N` in the same store. This probe tails that file — remembering
// a byte offset and reading only what was appended since — and reports the
// two things a progress line needs: how many turns the child has taken and
// what its last tool call was.
//
// Deliberately NOT the session follower. That actor spends a `sessions show`
// subprocess and re-parses the whole document per scan, which is the right
// price for canonical, ordered commits and the wrong one for a line that only
// ever shows the newest fact; driving it by poll would pay O(history) every
// second per running child. Nothing here is canonical: a missed line costs a
// stale progress line until the next append, not a hole in a transcript.

///|
/// How often a probe re-checks its record. The child's appends do not reach
/// the host as events (that is the whole problem), so there is nothing to
/// kick off — this interval IS the update rate. Slow enough that four
/// concurrent workers stay cheap, fast enough to read as live.
const SubrunProbeIntervalMs = 1500

///|
/// The most one poll will read. A child that appended a huge tool output
/// between polls yields its tail in the next pass instead of the host
/// allocating the whole burst at once; progress is a newest-fact display, so
/// arriving a poll late is not a loss.
let subrun_probe_max_chunk : Int64 = 128 * 1024

///|
/// A probe's place in one child's record.
priv struct SubrunProbeState {
  path : String
  mut offset : Int64
  /// The last bytes consumed, re-checked at their own position before the
  /// offset is trusted again. The store repairs a torn tail by writing a
  /// temp file and renaming it over the record
  /// (`agent_session/store/store.mbt::write_text_atomic`), and the
  /// replacement carries the newly appended event too — so it is usually
  /// LONGER than what was read, and a length check alone cannot see it. An
  /// offset carried onto a different inode would skip part of the record and
  /// splice a stale carry onto unrelated bytes.
  mut anchor : Bytes
  /// Bytes after the last newline: a poll can land mid-line, and half a JSON
  /// object is not news. Held as bytes, not text, so a chunk boundary inside
  /// a multi-byte character cannot corrupt the line it belongs to.
  mut carry : Bytes
  mut steps : Int
  mut activity : String
}

///|
/// The record file a durable session's events are appended to. The layout is
/// the store's (`<root>/sessions/<id>/openseek_session-<id>.jsonl`); the host
/// reads it directly here rather than through the engine, which is the point.
fn subrun_record_path(root : String, session : String) -> String {
  "\{root}/sessions/\{session}/openseek_session-\{session}.jsonl"
}

///|
/// Read whatever the child appended since the last poll and fold it into the
/// state. Returns whether the reported progress changed.
///
/// Every failure is silent and non-fatal: the record may not exist yet (the
/// child is still starting), may be mid-write, or may hold a line this build
/// cannot decode. A progress line is worth exactly as much as its next
/// successful poll.
async fn SubrunProbeState::poll(self : SubrunProbeState) -> Bool {
  let file = @fs.open(self.path, mode=ReadOnly) catch { _ => return false }
  defer file.close()
  let size = file.size() catch { _ => return false }
  // A record that shrank, or whose bytes at the offset are no longer the
  // ones that were read there, was rewritten under us. Restart from its head
  // rather than reading from a stale offset into the middle of a line.
  if size < self.offset || !anchored_at(file, self.offset, self.anchor) {
    self.offset = 0
    self.carry = b""
    self.anchor = b""
    // The counters describe what was read from THIS file; recounting from
    // its head means starting them over, or every surviving item would be
    // counted twice.
    self.steps = 0
    self.activity = ""
  }
  if size <= self.offset {
    return false
  }
  let want = size - self.offset
  let take = if want > subrun_probe_max_chunk {
    subrun_probe_max_chunk
  } else {
    want
  }
  let chunk = file.read_exactly_at(take.to_int(), position=self.offset) catch {
    _ => return false
  }
  self.offset = self.offset + take
  self.anchor = anchor_of(chunk)
  let pending = self.carry + chunk
  let mut changed = false
  let mut line_start = 0
  for index in 0..<pending.length() {
    if pending[index] != b'\n' {
      continue
    }
    if self.consume(pending[line_start:index]) {
      changed = true
    }
    line_start = index + 1
  }
  self.carry = pending[line_start:].to_owned()
  changed
}

///|
/// Fold one complete record line into the state, reporting whether what a
/// reader would see moved. The header line and any item this build does not
/// know about are simply not progress.
fn SubrunProbeState::consume(self : SubrunProbeState, line : BytesView) -> Bool {
  let text = @utf8.decode_lossy(line.to_owned())
    .trim(chars="\r\n \t")
    .to_owned()
  if text.is_empty() {
    return false
  }
  let json = @json.parse(text) catch { _ => return false }
  guard json is Object(fields) && fields.get("item") is Some(Object(item)) else {
    return false
  }
  guard item.get("kind") is Some(String(kind)) else { return false }
  match kind {
    "assistant" => {
      self.steps = self.steps + 1
      // The child records its assistant item BEFORE running the calls in it,
      // so this is the only account of what a slow tool is doing while it
      // runs — waiting for the `tool_result` would leave the lane showing
      // the previous action for exactly the calls worth explaining.
      match item.get("payload") {
        Some(Object(payload)) =>
          if last_tool_call_name(payload) is Some(name) {
            self.activity = name
          }
        _ => ()
      }
      true
    }
    "tool_result" => {
      guard item.get("payload") is Some(Object(payload)) else { return false }
      let activity = match payload.get("brief") {
        Some(String(brief)) if !brief.trim(chars=" ").is_empty() => brief
        _ =>
          match payload.get("tool_name") {
            Some(String(name)) => name
            _ => return false
          }
      }
      let changed = activity != self.activity
      self.activity = activity
      changed
    }
    _ => false
  }
}

///|
/// The tail of a chunk, kept as the next poll's proof that the file at the
/// offset is still the file that was read. Short: it only has to be long
/// enough that a different record is unlikely to carry the same bytes at the
/// same position, and it is re-read in full on every poll.
const SubrunAnchorBytes = 48

///|
fn anchor_of(chunk : Bytes) -> Bytes {
  if chunk.length() <= SubrunAnchorBytes {
    chunk
  } else {
    chunk[chunk.length() - SubrunAnchorBytes:].to_owned()
  }
}

///|
/// Whether the bytes ending at `offset` are still the ones read there. An
/// empty anchor (nothing consumed yet) is vacuously true; a read that fails
/// reports false, which costs one re-read from the head.
async fn anchored_at(file : @fs.File, offset : Int64, anchor : Bytes) -> Bool {
  if anchor.length() == 0 {
    return true
  }
  let start = offset - anchor.length().to_int64()
  if start < 0 {
    return false
  }
  let seen = file.read_exactly_at(anchor.length(), position=start) catch {
    _ => return false
  }
  seen == anchor
}

///|
/// The name of the last tool call an assistant item requested, or `None` when
/// it requested none (a plain message, or an item this build cannot read).
fn last_tool_call_name(payload : Map[String, Json]) -> String? {
  guard payload.get("tool_calls") is Some(Array(calls)) else { return None }
  let mut name = None
  for call in calls {
    if call is Object(fields) && fields.get("name") is Some(String(value)) {
      name = Some(value)
    }
  }
  name
}

///|
/// Tail one sub-run's record until the task is cancelled, reporting each
/// advance through `publish`.
///
/// The caller owns the lifetime: it starts this when the `subrun_started`
/// bracket arrives and cancels it at `subrun_finished`. Nothing here decides
/// when a sub-run is over — the brackets already say so, and a probe that
/// guessed from the record could only guess late.
pub async fn follow_subrun_progress(
  root~ : String,
  parent_session~ : String,
  id~ : String,
  publish~ : async (@protocol.SubrunProgressPayload) -> Unit,
) -> Unit {
  let session = "\{parent_session}-\{id}"
  let state = {
    path: subrun_record_path(root, session),
    offset: 0,
    carry: b"",
    anchor: b"",
    steps: 0,
    activity: "",
  }
  for ;; {
    @async.sleep(SubrunProbeIntervalMs)
    if state.poll() {
      publish({ id, session, steps: state.steps, activity: state.activity })
    }
  }
}
