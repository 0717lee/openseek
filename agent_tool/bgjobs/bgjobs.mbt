///|
/// Default retained-output budget for a background job, in characters. Matches
/// the `shell` tool's foreground default so a command reads the same whether it
/// runs in the foreground or the background.
let default_max_output_chars : Int = 12000

///|
/// After the direct child exits, how long to let the reader keep draining the
/// pipe before force-closing it. In the normal case the reader hits EOF almost
/// immediately (the child closed its write end), capturing all buffered output;
/// this grace only elapses when a descendant inherited and is holding the pipe
/// open, in which case there is no more of the job's own output to wait for.
let reader_drain_grace_ms : Int = 200

///|
/// Terminal or live state of a background job.
///
/// - `Running`: the child is still executing.
/// - `Exited(code)`: the child exited on its own with `code`.
/// - `Stopped`: the child was cancelled (`stop`, a reader error, or session
///   teardown) before a natural exit — no exit code is available.
pub(all) enum BgJobStatus {
  Running
  Exited(Int)
  Stopped
} derive(Eq)

///|
/// Session-scoped registry of background ("detached") jobs. Mirrors the
/// `moon_check` runtime: every child is spawned on `scope.group()`, so each
/// job's process is cancelled when the agent session's task group ends.
///
/// Cancellation reaches only the directly spawned process, exactly like the
/// foreground `shell` tool and `moon_check` (all use `@process.hard_cancel`):
/// the process library exposes no process-group / job-object kill, so a command
/// that daemonizes or backgrounds its own children can leave those descendants
/// running after the job is reported terminal. `stop`/teardown therefore
/// guarantee the launched process is gone, not its entire process tree.
///
/// One `BgJobRuntime` is created per session and shared by the `shell`
/// (`run_in_background`), `shell_output`, and `shell_stop` tools, so a job
/// started by one is visible to the others.
///
/// `new` captures the session group at construction, so `BgJobRuntime` itself is
/// not parameterised by the group's return type — it can be an optional tool
/// argument (e.g. on `shell`) without leaking an unresolved type variable to
/// callers that never start background jobs.
pub struct BgJobRuntime {
  // Spawn a child process on the captured session group, with stdout+stderr
  // merged into `writer`. Captured so the runtime type is not generic.
  priv spawn_process : async (
    String,
    Array[String],
    String?,
    &@process.ProcessOutput,
  ) -> @process.Process
  // Spawn the per-job monitor task on that same group.
  priv spawn_monitor : (async () -> Unit) -> Unit
  priv jobs : Map[String, BgJob]
  priv mut next_index : Int
}

///|
/// One background job. `output` keeps the trailing `max_output_chars` characters
/// of merged stdout+stderr; `seq` bumps on every appended chunk so a poller can
/// tell whether new output has arrived. Fully private — callers only ever see a
/// `BgJobSnapshot` via `snapshot`/`list`.
priv struct BgJob {
  id : String
  command : String
  cwd : String?
  process : @process.Process
  max_output_chars : Int
  mut status : BgJobStatus
  mut output : String
  mut output_truncated : Bool
  // Trailing bytes of an incomplete UTF-8 sequence split across read chunks,
  // decoded once the rest arrives (or lossily at EOF) so a multi-byte character
  // on a chunk boundary is not corrupted into replacement characters.
  mut pending_bytes : Bytes
  mut seq : Int
  mut exit_code : Int?
  // Set by `stop` before it cancels the child, so the monitor reports `Stopped`
  // rather than the kill signal's exit code once `wait` returns.
  mut cancel_requested : Bool
}

///|
/// An immutable view of a job's current state, returned by `snapshot`/`list` so
/// callers never hold a live reference into the registry.
pub struct BgJobSnapshot {
  id : String
  command : String
  cwd : String?
  status : BgJobStatus
  output : String
  output_truncated : Bool
  seq : Int
  exit_code : Int?
}

///|
/// Create an empty runtime whose jobs are owned by `scope.group()`. The group is
/// captured into spawn closures, so the returned runtime is not generic.
pub fn[X] BgJobRuntime::new(
  scope : @agent_runtime.AgentTaskScope[X],
) -> BgJobRuntime {
  let group = scope.group()
  {
    spawn_process: (program, args, cwd, writer) => {
      @process.spawn(
        group,
        program,
        args,
        stdout=writer,
        stderr=writer,
        cwd?=cwd.map(cwd => cwd.view()),
        cancel_handler=@process.hard_cancel(),
        no_wait=true,
      )
    },
    spawn_monitor: task => {
      group.spawn_bg(task, no_wait=true, allow_failure=true)
    },
    jobs: {},
    next_index: 1,
  }
}

///|
fn BgJobRuntime::next_id(self : BgJobRuntime) -> String {
  let id = "bg-\{self.next_index}"
  self.next_index += 1
  id
}

///|
/// Spawn `program args` as a background job on the session group and return its
/// id. Merged stdout+stderr streams into the job's retained-output buffer; the
/// job keeps running after this returns. `command` is the human-readable command
/// line shown to the model (e.g. the original shell `cmd`).
pub async fn BgJobRuntime::start(
  self : BgJobRuntime,
  program~ : String,
  args~ : Array[String],
  command~ : String,
  cwd? : String,
  max_output_chars? : Int = default_max_output_chars,
) -> String {
  let id = self.next_id()
  // A non-positive budget would slip past retain_tail's cap and retain output
  // unbounded; keep at least one character.
  let max_output_chars = if max_output_chars > 0 { max_output_chars } else { 1 }
  let (reader, writer) = @process.read_from_process()
  let process = (self.spawn_process)(program, args, cwd, writer)
  self.jobs[id] = {
    id,
    command,
    cwd,
    process,
    max_output_chars,
    status: Running,
    output: "",
    output_truncated: false,
    pending_bytes: b"",
    seq: 0,
    exit_code: None,
    cancel_requested: false,
  }
  (self.spawn_monitor)(() => self.monitor(id, reader, process))
  id
}

///|
/// Supervise one job: drain its merged output while, *independently*, awaiting
/// the direct child's exit. Coupling the two (read until EOF, then `wait`) would
/// hang forever when the child exits but a descendant inherits and holds the
/// pipe open — so a concurrent reader task drains bytes, and `process.wait()` is
/// the authoritative exit signal that then closes the reader to unblock it.
async fn BgJobRuntime::monitor(
  self : BgJobRuntime,
  id : String,
  reader : @process.ReadFromProcess,
  process : @process.Process,
) -> Unit {
  let reader_done : @async.Queue[Unit] = Queue(kind=Unbounded)
  @async.with_task_group(reads => {
    // Drain output concurrently; signal `reader_done` on EOF, a read error, or
    // `reader.close()`.
    reads.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      defer ignore(reader_done.try_put(()) catch { _ => false })
      for ;; {
        match (reader.read_some(max_len=1024) catch { _ => None }) {
          None => break
          Some(bytes) => self.append_chunk(id, bytes)
        }
      }
    }
    // The direct child's exit is authoritative, independent of the pipe. A
    // concurrent `stop` cancels the process, so `wait` may raise or return a
    // kill signal's code — every path lands on a terminal status.
    let terminal = try {
      let code = process.wait()
      if self.job_cancel_requested(id) {
        Stopped
      } else {
        Exited(code)
      }
    } catch {
      error => {
        // Session teardown cancelled this task; unblock the reader and propagate
        // so structured concurrency still unwinds.
        if @async.is_being_cancelled() {
          reader.close()
          raise error
        }
        Stopped
      }
    }
    // The child is gone, but the pipe may still hold output it wrote before
    // exiting. Let the reader drain to EOF so nothing is lost; only if it is
    // still blocked after a short grace — a descendant is holding the pipe open —
    // force it closed. Publish the terminal status only after the drain, so a
    // poller never sees `Exited` with truncated output.
    match
      @async.with_timeout_opt(reader_drain_grace_ms, () => reader_done.get()) {
      Some(_) => ()
      None =>
        // A descendant is holding the pipe open, so EOF never comes. The reader
        // is blocked on an empty pipe (not appending), so `pending_bytes` is
        // already final; close the fd and let the stalled reader task be reaped
        // when this group returns — don't wait for it (that would deadlock).
        reader.close()
    }
    // The reader has drained all it will (or is idle on a held-open pipe), so
    // surface any leftover half-decoded bytes and publish the terminal status
    // together — a poller can never observe a terminal snapshot missing the
    // job's final output.
    self.flush_pending(id)
    self.finish(id, terminal)
  })
}

///|
fn BgJobRuntime::job_cancel_requested(self : BgJobRuntime, id : String) -> Bool {
  self.jobs.get(id).map(job => job.cancel_requested).unwrap_or(false)
}

///|
/// Append a raw output chunk. Prepends any bytes left undecoded from the
/// previous chunk, appends the longest valid-UTF-8 prefix, and carries the
/// trailing ≤3 bytes of a split multi-byte character over to the next chunk.
fn BgJobRuntime::append_chunk(
  self : BgJobRuntime,
  id : String,
  chunk : Bytes,
) -> Unit {
  guard self.jobs.get(id) is Some(job) else { return }
  let buffer = Buffer()
  buffer.write_bytes(job.pending_bytes)
  buffer.write_bytes(chunk)
  let (text, rest) = split_valid_utf8(buffer.to_bytes())
  job.pending_bytes = rest
  self.append_text(id, text)
}

///|
/// At end-of-stream, decode any leftover trailing bytes lossily so a truncated
/// final character surfaces (as a replacement char) rather than vanishing.
fn BgJobRuntime::flush_pending(self : BgJobRuntime, id : String) -> Unit {
  guard self.jobs.get(id) is Some(job) else { return }
  if job.pending_bytes.length() > 0 {
    let text = @utf8.decode_lossy(job.pending_bytes)
    job.pending_bytes = b""
    self.append_text(id, text)
  }
}

///|
/// Append decoded text, keeping only the trailing `max_output_chars` characters
/// and latching `output_truncated` once anything is dropped. Bumps `seq` when
/// there is something to add.
fn BgJobRuntime::append_text(
  self : BgJobRuntime,
  id : String,
  text : String,
) -> Unit {
  guard text != "" else { return }
  guard self.jobs.get(id) is Some(job) else { return }
  let combined = job.output + text
  job.output = retain_tail(combined, job.max_output_chars)
  job.output_truncated = job.output_truncated ||
    combined.char_length() > job.max_output_chars
  job.seq += 1
}

///|
/// Split `bytes` into the text to surface now and the trailing bytes to carry
/// to the next chunk. Only a suffix that can still *complete* a multi-byte UTF-8
/// sequence is carried; everything else — including invalid bytes such as
/// `0xff` — is decoded lossily now, so a running job's binary or corrupt output
/// is never hidden until more bytes happen to arrive.
fn split_valid_utf8(bytes : Bytes) -> (String, Bytes) {
  let end = bytes.length() - incomplete_suffix_len(bytes)
  let tail = Buffer()
  tail.write_bytes(bytes[end:])
  (@utf8.decode_lossy(bytes[:end]), tail.to_bytes())
}

///|
/// The number of trailing bytes (0–3) that begin an incomplete but still
/// completable multi-byte UTF-8 sequence. Returns 0 when the tail is already
/// complete, is a stray continuation byte, or is an invalid lead (e.g. `0xff`),
/// so those bytes are surfaced immediately rather than held for output that may
/// never come.
fn incomplete_suffix_len(bytes : Bytes) -> Int {
  let len = bytes.length()
  let lookback = if len < 3 { len } else { 3 }
  for i in 0..<lookback {
    let pos = len - 1 - i
    let b = bytes[pos].to_int()
    if b < 0x80 {
      // A complete ASCII byte; anything after it is a stray continuation.
      return 0
    }
    if b >= 0xC0 {
      // A lead byte: carry it only while its sequence is still incomplete AND
      // the continuation bytes already seen are legal for it — otherwise the
      // sequence is malformed (overlong / out of range) and must be surfaced
      // now rather than held for a completion that can never be valid.
      let expected = utf8_sequence_len(b)
      let have = len - pos
      guard expected != 0 && expected > have else { return 0 }
      for j in 1..<have {
        let (lo, hi) = continuation_range(b, j)
        let cb = bytes[pos + j].to_int()
        if cb < lo || cb > hi {
          return 0
        }
      }
      return have
    }
    // 0x80..=0xBF: a continuation byte — keep scanning back for its lead.
  }
  0
}

///|
/// The total byte length of a UTF-8 sequence starting with lead byte `b`, or 0
/// when `b` is not a valid multi-byte lead (ASCII, a continuation byte, an
/// overlong `0xC0`/`0xC1`, or an out-of-range `0xF5`..`0xFF`).
fn utf8_sequence_len(b : Int) -> Int {
  if b >= 0xF0 && b <= 0xF4 {
    4
  } else if b >= 0xE0 && b <= 0xEF {
    3
  } else if b >= 0xC2 && b <= 0xDF {
    2
  } else {
    0
  }
}

///|
/// The legal byte range for the `j`-th continuation byte (1-based, after the
/// lead) of a UTF-8 sequence led by `lead`. The first continuation is
/// restricted for the leads that would otherwise admit overlong encodings
/// (`0xE0`, `0xF0`), surrogates (`0xED`), or out-of-range code points (`0xF4`);
/// every other position is the full `0x80..=0xBF`.
fn continuation_range(lead : Int, j : Int) -> (Int, Int) {
  if j == 1 {
    if lead == 0xE0 {
      (0xA0, 0xBF)
    } else if lead == 0xED {
      (0x80, 0x9F)
    } else if lead == 0xF0 {
      (0x90, 0xBF)
    } else if lead == 0xF4 {
      (0x80, 0x8F)
    } else {
      (0x80, 0xBF)
    }
  } else {
    (0x80, 0xBF)
  }
}

///|
/// Set a job's terminal status once. Later calls (e.g. a `stop` racing a natural
/// exit) are ignored so the first terminal state wins.
fn BgJobRuntime::finish(
  self : BgJobRuntime,
  id : String,
  status : BgJobStatus,
) -> Unit {
  guard self.jobs.get(id) is Some(job) else { return }
  guard job.status is Running else { return }
  job.status = status
  job.exit_code = match status {
    Exited(code) => Some(code)
    _ => None
  }
}

///|
/// The current state of job `id`, or `None` if there is no such job.
pub fn BgJobRuntime::snapshot(
  self : BgJobRuntime,
  id : String,
) -> BgJobSnapshot? {
  self.jobs.get(id).map(job => job.to_snapshot())
}

///|
/// All jobs' current states, in id order.
pub fn BgJobRuntime::list(self : BgJobRuntime) -> Array[BgJobSnapshot] {
  let out = []
  for _, job in self.jobs {
    out.push(job.to_snapshot())
  }
  out
}

///|
/// Cancel a running job and wait for its child to be reaped. Returns `false`
/// only when there is no such job; an already-terminal job returns `true`
/// without doing anything.
pub async fn BgJobRuntime::stop(self : BgJobRuntime, id : String) -> Bool {
  guard self.jobs.get(id) is Some(job) else { return false }
  guard job.status is Running else { return true }
  job.cancel_requested = true
  job.process.cancel()
  // `cancel` is asynchronous and the monitor reaps the child via `wait`. Observe
  // the status transition rather than a one-shot signal, so any number of
  // concurrent `stop` callers all return once the job lands terminal — none can
  // hang waiting on a signal another caller already consumed.
  for ;; {
    if self.jobs.get(id) is Some(job) && !(job.status is Running) {
      return true
    }
    @async.sleep(5)
  }
}

///|
fn BgJob::to_snapshot(self : BgJob) -> BgJobSnapshot {
  {
    id: self.id,
    command: self.command,
    cwd: self.cwd,
    status: self.status,
    output: self.output,
    output_truncated: self.output_truncated,
    seq: self.seq,
    exit_code: self.exit_code,
  }
}

///|
/// Keep only the trailing `max_chars` characters of `text`.
fn retain_tail(text : String, max_chars : Int) -> String {
  guard max_chars > 0 else { return "" }
  let len = text.char_length()
  if len <= max_chars {
    text
  } else {
    match text.offset_of_nth_char(len - max_chars) {
      Some(start) => "\{text[start:]}"
      None => text
    }
  }
}
