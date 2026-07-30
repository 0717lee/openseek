// The host side of the integrated terminal: a session table plus the ops the
// IPC layer calls into. PTY processes themselves are owned by the pump
// (`run_terminal_pump`), which runs inside the host services' task group —
// see pump.mbt.

///|
/// A host-side failure with a user-facing message; the IPC boundary
/// translates it into the error the webview displays.
pub suberror TerminalError {
  TerminalError(String)
}

///|
/// One push from a terminal session to the webview. `Output` carries raw PTY
/// bytes (chunk boundaries may split UTF-8 sequences, so the wire encoding
/// must stay byte-transparent); `Exited` reports the child's exit code after
/// the session drained.
pub(all) enum TerminalPush {
  Output(id~ : Int, data~ : Bytes)
  Exited(id~ : Int, code~ : Int)
}

///|
/// Stop reading the PTY once this many emitted bytes are unacknowledged; the
/// kernel PTY buffer then fills and the child blocks, so a `cat` of a huge
/// file cannot flood the webview.
const HighWatermark = 262144

///|
/// Resume reading once acknowledgements bring the debt below this.
const LowWatermark = 65536

///|
priv struct TerminalSession {
  pty : @pty.Pty
  /// Bytes emitted to the webview but not yet acknowledged.
  mut unacked : Int
  /// Wakes the session's read loop when acknowledgements drain the debt or
  /// the session starts closing.
  cond : @cond_var.Cond
  mut closing : Bool
}

///|
priv struct OpenRequest {
  id : Int
  /// The page connection that submitted this request. A later connect
  /// handshake invalidates it even if the pump has already dequeued it.
  connection_generation : Int
  argv : Array[String]
  /// The directory passed directly to the PTY process spawn.
  cwd : String
  cols : Int
  rows : Int
  /// Spawn outcome for the waiting `open_terminal` call.
  reply : @async.Queue[Result[Unit, String]]
}

///|
/// The terminal subsystem's shared state: the pump's mailbox of pending
/// spawns, the table of live sessions, and the current page connection.
struct TerminalState {
  requests : @async.Queue[OpenRequest]
  sessions : Map[Int, TerminalSession]
  mut next_id : Int
  /// Incremented by the connect handshake so opens from an older page cannot
  /// publish a session after that page has gone away.
  mut connection_generation : Int
}

///|
pub fn new_terminal_state() -> TerminalState {
  {
    requests: Queue(kind=Unbounded),
    sessions: Map([]),
    next_id: 1,
    connection_generation: 0,
  }
}

///|
/// Open a terminal session in `cwd` and return its id once the child is
/// running. Without `command`, POSIX launches `$SHELL -l` and Windows launches
/// `%COMSPEC%`; with it, that argv runs directly in the session's PTY instead.
/// Requires `run_terminal_pump` to be running (the host services' task
/// group), otherwise the call waits until it is.
pub async fn open_terminal(
  state : TerminalState,
  cwd~ : String,
  cols~ : Int,
  rows~ : Int,
  command? : Array[String],
) -> Int {
  let argv = session_argv(command?)
  let id = state.next_id
  state.next_id = id + 1
  let reply : @async.Queue[Result[Unit, String]] = Queue(kind=Blocking(1))
  state.requests.put({
    id,
    connection_generation: state.connection_generation,
    argv,
    cwd,
    cols,
    rows,
    reply,
  })
  match reply.get() {
    Ok(_) => id
    Err(message) => raise TerminalError(message)
  }
}

///|
/// Write user input (already encoded as terminal input bytes) to a session.
pub async fn write_terminal(
  state : TerminalState,
  id~ : Int,
  data : Bytes,
) -> Unit {
  guard state.sessions.get(id) is Some(session) else {
    raise TerminalError("terminal \{id} is not open")
  }
  session.pty.write(data) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise TerminalError(@debug.render(Repr(error)))
  }
}

///|
/// Propagate a webview-side viewport change to the PTY.
pub fn resize_terminal(
  state : TerminalState,
  id~ : Int,
  cols~ : Int,
  rows~ : Int,
) -> Unit raise {
  guard state.sessions.get(id) is Some(session) else {
    raise TerminalError("terminal \{id} is not open")
  }
  session.pty.resize(cols~, rows~) catch {
    error => raise TerminalError("terminal resize failed: \{error}")
  }
}

///|
/// Acknowledge `bytes` of output the webview has finished rendering. Frees
/// the flow-control window so the session's read loop can continue.
pub fn ack_terminal(state : TerminalState, id~ : Int, bytes~ : Int) -> Unit {
  guard state.sessions.get(id) is Some(session) else { return }
  session.unacked -= bytes
  if session.unacked < 0 {
    session.unacked = 0
  }
  if session.unacked < LowWatermark {
    session.cond.signal()
  }
}

///|
/// Request a session's shutdown. The session task owns the actual teardown:
/// cancelling the child makes its read loop drain, emit `Exited`, and
/// release the PTY. Unknown ids are a no-op (the session already exited).
pub fn close_terminal(state : TerminalState, id~ : Int) -> Unit {
  guard state.sessions.get(id) is Some(session) else { return }
  session.closing = true
  session.cond.broadcast()
  session.pty.cancel()
}

///|
/// Retire every live session and invalidate every open requested by an older
/// page. A freshly (re)loaded page cannot reclaim the old page's terminal
/// tabs, including requests the pump has not published as sessions yet.
pub fn close_all_terminals(state : TerminalState) -> Unit {
  // Incrementing before the live-session sweep also covers requests that the
  // pump dequeued but whose PTY spawn has not completed.
  state.connection_generation += 1
  // Materialized: teardown mutates the table as sessions unwind.
  for id in state.sessions.keys().to_array() {
    close_terminal(state, id~)
  }
}
