///|
/// After the direct child exits, how long to let the reader keep draining the
/// pipe before force-closing it. In the normal case the reader hits EOF almost
/// immediately (the child closed its write end); this grace only elapses when a
/// descendant inherited and is holding the pipe open, in which case there is no
/// more of the job's own output to wait for. Mirrors the value in `bgjobs`.
let reader_drain_grace_ms : Int = 200

///|
/// Terminal or live state of one execution.
///
/// - `Running`: the child is executing and a tool call is awaiting it.
/// - `Backgrounded`: the child is still executing but detached — no call is
///   awaiting it (set by detach-on-timeout; the process keeps running).
/// - `Exited(code)`: the child exited on its own with `code`.
/// - `Killed`: the child was cancelled (`stop`, a reader error, or session
///   teardown) before a natural exit — no exit code is available.
pub(all) enum ExecStatus {
  Running
  Backgrounded
  Exited(Int)
  Killed
} derive(Eq, Debug)

///|
/// Whether a status is terminal (the child is gone).
pub fn ExecStatus::is_terminal(self : ExecStatus) -> Bool {
  match self {
    Exited(_) | Killed => true
    Running | Backgrounded => false
  }
}

///|
/// One shell command execution: a process spawned on the session group, its
/// merged stdout+stderr owned by a single `ShellOutputSink`, and a status flag.
/// This is the shared object behind both foreground `shell` and background jobs —
/// "foreground vs background" is only whether a tool call is currently awaiting
/// it, so detaching (later) is a status flip, not a re-route.
///
/// Cancellation reaches only the directly spawned process (like the foreground
/// `shell` tool and `moon_check`): the process library exposes no process-group
/// kill, so a command that daemonizes its own children can leave descendants
/// running after the execution is terminal.
pub struct ShellExecution {
  priv sink : ShellOutputSink
  priv process : @process.Process
  priv mut status : ExecStatus
  // Set before the child is cancelled (by `stop`, or by the output-limit kill)
  // so the monitor reports `Killed` rather than the kill signal's exit code.
  priv mut cancel_requested : Bool
  // Foreground semantics: kill the child once the sink fills (its output prefix
  // reached the hard cap), so an un-timed runaway producer cannot hang the tool
  // call. A background job leaves this false — it caps retention but keeps
  // running. Cleared by `background()`: a detached command becomes a background
  // job and should not be killed just for producing more output.
  priv mut kill_when_full : Bool
}

///|
/// Spawn `program args` on the session group with stdout+stderr merged into a
/// fresh sink, start a monitor task, and return the live execution. The child
/// keeps running after this returns; poll `status`/`output` or await terminal.
pub async fn[X] ShellExecution::start(
  scope : @agent_runtime.AgentTaskScope[X],
  program~ : String,
  args~ : Array[String],
  cwd? : String,
  inline_cap? : Int = default_inline_cap,
  hard_cap? : Int = default_hard_cap,
  kill_when_full? : Bool = false,
) -> ShellExecution {
  let group = scope.group()
  let sink = ShellOutputSink::new(inline_cap~, hard_cap~)
  let (reader, writer) = @process.read_from_process()
  let process = @process.spawn(
    group,
    program,
    args,
    stdout=writer,
    stderr=writer,
    cwd?=cwd.map(cwd => cwd.view()),
    cancel_handler=@process.hard_cancel(),
    no_wait=true,
  )
  let exec = {
    sink,
    process,
    status: Running,
    cancel_requested: false,
    kill_when_full,
  }
  group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
    exec.monitor(reader, process)
  }
  exec
}

///|
/// Supervise the execution: drain merged output while, *independently*, awaiting
/// the direct child's exit. Coupling the two (read to EOF, then `wait`) would
/// hang forever when the child exits but a descendant holds the pipe open — so a
/// concurrent reader drains bytes and `process.wait()` is the authoritative exit
/// signal that then closes the reader to unblock it.
async fn ShellExecution::monitor(
  self : ShellExecution,
  reader : @process.ReadFromProcess,
  process : @process.Process,
) -> Unit {
  let reader_done : @async.Queue[Unit] = Queue(kind=Unbounded)
  @async.with_task_group(reads => {
    reads.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      defer ignore(reader_done.try_put(()) catch { _ => false })
      for ;; {
        match (reader.read_some(max_len=1024) catch { _ => None }) {
          None => break
          Some(bytes) => {
            self.sink.append_chunk(bytes)
            // Foreground output-limit kill: once the sink fills, stop the child
            // so an un-timed runaway producer cannot block forever. The monitor
            // then reports `Killed` (cancel_requested), and `output_truncated`
            // marks it as the output-limit case.
            if self.kill_when_full &&
              self.sink.truncated() &&
              !self.cancel_requested {
              self.cancel_requested = true
              self.process.cancel()
            }
          }
        }
      }
    }
    // The direct child's exit is authoritative, independent of the pipe. A
    // concurrent `stop` cancels the process, so `wait` may raise or return a
    // kill signal's code — every path lands on a terminal status.
    let terminal = try {
      let code = process.wait()
      if self.cancel_requested {
        Killed
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
        Killed
      }
    }
    // The child is gone, but the pipe may still hold output it wrote before
    // exiting. Let the reader drain to EOF so nothing is lost; only if it is
    // still blocked after a short grace — a descendant is holding the pipe open —
    // force it closed.
    match
      @async.with_timeout_opt(reader_drain_grace_ms, () => reader_done.get()) {
      Some(_) => ()
      None => reader.close()
    }
    // Surface any leftover half-decoded bytes, then publish the terminal status —
    // in that order, so a poller can never observe a terminal execution missing
    // the job's final output.
    self.sink.finish()
    self.set_terminal(terminal)
  })
}

///|
/// Move to a terminal status, unless already terminal (a `stop` that raced the
/// natural exit must not clobber the recorded outcome).
fn ShellExecution::set_terminal(
  self : ShellExecution,
  status : ExecStatus,
) -> Unit {
  guard !self.status.is_terminal() else { return }
  self.status = status
}

///|
/// Stop the execution: cancel the child and return once it lands terminal.
/// Idempotent and safe under concurrent callers — each observes the status
/// transition rather than a one-shot signal, so none can hang on a signal
/// another already consumed. Returns `false` only for an already-terminal job.
pub async fn ShellExecution::stop(self : ShellExecution) -> Bool {
  guard !self.status.is_terminal() else { return false }
  self.request_stop()
  for ;; {
    if self.status.is_terminal() {
      return true
    }
    @async.sleep(5)
  }
}

///|
/// Synchronously request cancellation of the child (mark it and fire the process
/// cancel) without awaiting the terminal transition. `Process::cancel` is sync,
/// so this is safe to call while a turn is being cancelled — where awaiting is
/// not — to stop a session-group execution before it can outlive the turn as an
/// orphan. The monitor (on the session group) then reaps it to `Killed`.
pub fn ShellExecution::request_stop(self : ShellExecution) -> Unit {
  self.cancel_requested = true
  self.process.cancel()
}

///|
/// Await the execution reaching a terminal status. Observes the status set by
/// the monitor, so it composes with concurrent `stop`/`background` callers.
pub async fn ShellExecution::wait(self : ShellExecution) -> Unit {
  for ;; {
    if self.status.is_terminal() {
      return
    }
    @async.sleep(5)
  }
}

///|
/// Detach the execution: flip `Running` to `Backgrounded` so no call is awaiting
/// it while the process keeps running. A no-op (returns `false`) once terminal or
/// already backgrounded.
pub fn ShellExecution::background(self : ShellExecution) -> Bool {
  guard self.status is Running else { return false }
  self.status = Backgrounded
  // No longer a foreground call: keep running and cap retention like any
  // background job, rather than being killed for filling the sink.
  self.kill_when_full = false
  true
}

///|
/// The current live or terminal status.
pub fn ShellExecution::status(self : ShellExecution) -> ExecStatus {
  self.status
}

///|
/// The child's exit code, if it exited on its own.
pub fn ShellExecution::exit_code(self : ShellExecution) -> Int? {
  match self.status {
    Exited(code) => Some(code)
    _ => None
  }
}

///|
/// The retained output (the prefix, up to the hard cap).
pub fn ShellExecution::output(self : ShellExecution) -> String {
  self.sink.text()
}

///|
/// Whether output was dropped at the hard cap.
pub fn ShellExecution::output_truncated(self : ShellExecution) -> Bool {
  self.sink.truncated()
}

///|
/// Retained output length, in characters.
pub fn ShellExecution::size(self : ShellExecution) -> Int {
  self.sink.size()
}

///|
/// Output version, bumped whenever retained output grows — for poll change
/// detection.
pub fn ShellExecution::seq(self : ShellExecution) -> Int {
  self.sink.seq()
}

///|
/// Retained output added since `offset` characters — for polling new output.
pub fn ShellExecution::tail_from(self : ShellExecution, offset : Int) -> String {
  self.sink.tail_from(offset)
}

///|
/// Whether the consumer should render a file pointer instead of inline output.
pub fn ShellExecution::over_inline_cap(self : ShellExecution) -> Bool {
  self.sink.over_inline_cap()
}
