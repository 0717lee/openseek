// The terminal panel's public state machine. The emulator widget itself is
// imperative DOM outside the model (see host.mbt); this state tracks only
// what the update loop decides: whether the panel shows, and which PTY
// session (if any) the panel is bound to.

///|
/// The lifecycle of the panel's PTY session. Every non-idle phase names the
/// conversation the session was opened for and a display label for its
/// workspace: the shell outlives conversation switches (its running jobs
/// and history are the user's work), so the titlebar must be able to say
/// where a shell opened elsewhere actually lives.
pub(all) enum Phase {
  /// No session opened yet.
  Idle
  /// `terminal_open` is in flight.
  Opening(session~ : String, workspace~ : String)
  /// A live PTY session, `id` as the host numbered it.
  Running(session~ : String, workspace~ : String, id~ : Int)
  /// The child exited; the panel offers a restart.
  Exited(session~ : String, workspace~ : String, code~ : Int)
  /// Opening or driving the session failed; the panel shows the message
  /// and offers a restart.
  Failed(session~ : String, workspace~ : String, message~ : String)
} derive(Eq)

///|
pub(all) struct State {
  open : Bool
  phase : Phase
} derive(Eq)

///|
pub fn State::empty() -> State {
  { open: false, phase: Idle }
}

///|
/// The conversation and workspace label a non-idle phase belongs to.
fn Phase::binding(self : Phase) -> (String, String)? {
  match self {
    Idle => None
    Opening(session~, workspace~) => Some((session, workspace))
    Running(session~, workspace~, ..) => Some((session, workspace))
    Exited(session~, workspace~, ..) => Some((session, workspace))
    Failed(session~, workspace~, ..) => Some((session, workspace))
  }
}

///|
/// The terminal package's view of the active conversation, recomputed per
/// dispatch by the main package (mirrors `@fileeditor.Ctx`).
pub(all) struct Ctx {
  session : String
  workspace : @pathx.Absolute?
  dark_mode : Bool
}

///|
pub(all) enum Msg {
  /// Show/hide the panel (the shell keeps running while hidden).
  ToggleTerminal
  /// The emulator is mounted, fitted, and reports its grid size.
  EmulatorReady(cols~ : Int, rows~ : Int)
  /// `terminal_open` replies, tagged with the conversation it was for.
  Opened(session~ : String, id~ : Int)
  OpenFailed(session~ : String, message~ : String)
  /// Keystrokes as the emulator encoded them.
  UserInput(data~ : String)
  /// The emulator re-fit to a new grid size.
  ViewportResized(cols~ : Int, rows~ : Int)
  /// `terminal_output` event: base64 of raw PTY bytes.
  Output(id~ : Int, data~ : String, bytes~ : Int)
  /// The emulator finished rendering a chunk; flow-control ack.
  OutputRendered(id~ : Int, bytes~ : Int)
  /// `terminal_exit` event.
  SessionExited(id~ : Int, code~ : Int)
  /// Spawn a fresh session after an exit or failure.
  RestartTerminal
}
