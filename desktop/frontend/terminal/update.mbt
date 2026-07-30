// The panel's update loop. One deliberate property: the shell OUTLIVES
// conversation switches. Its running jobs, history, and working directory
// are the user's work, so nothing here retires a session just because the
// active conversation changed — the titlebar names the workspace the shell
// lives in instead (see `panel_view`), and a restart after the shell exits
// respawns in whatever conversation is active then. Sessions end when their
// child exits, when the user restarts, or when the webview disconnects (the
// host tears its task group down).

///|
/// The display label for the active conversation's workspace: the project
/// directory's name, or "scratch" for a conversation without one.
fn workspace_label(ctx : Ctx) -> String {
  guard ctx.workspace is Some(workspace) else { return "scratch" }
  let text = workspace.0
  let mut label = text
  for part in text.split("/") {
    if !part.is_empty() {
      label = part.to_owned()
    }
  }
  label
}

///|
pub fn update(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  state : State,
  ctx : Ctx,
) -> (@cmd.Cmd, State) {
  match msg {
    ToggleTerminal =>
      if state.open {
        // Hide only — the shell keeps running for the panel's return.
        (@cmd.none, { ..state, open: false })
      } else {
        // Mount reports `EmulatorReady`, which spawns a session if none
        // runs; an existing session just gets re-fit and refocused.
        (
          @cmd.batch([request_terminal_mount(dispatch, ctx), focus_terminal()]),
          { ..state, open: true },
        )
      }
    EmulatorReady(cols~, rows~) =>
      match state.phase {
        Idle | Exited(..) | Failed(..) =>
          (
            open_session(dispatch, ctx, cols, rows),
            {
              ..state,
              phase: Opening(
                session=ctx.session,
                workspace=workspace_label(ctx),
              ),
            },
          )
        Opening(..) | Running(..) => (@cmd.none, state)
      }
    Opened(session~, id~) =>
      if state.phase is Opening(session=expected, workspace~) &&
        expected == session {
        (wire_session(), { ..state, phase: Running(session~, workspace~, id~) })
      } else {
        // A stale reply (the panel restarted meanwhile); the session
        // belongs to nobody, so retire it on the host.
        (send_close(id), state)
      }
    OpenFailed(session~, message~) =>
      if state.phase is Opening(session=expected, workspace~) &&
        expected == session {
        (@cmd.none, { ..state, phase: Failed(session~, workspace~, message~) })
      } else if state.phase is Running(session=expected, workspace~, ..) &&
        expected == session {
        // A steady-state op (input) failed against a session the host no
        // longer has.
        (@cmd.none, { ..state, phase: Failed(session~, workspace~, message~) })
      } else {
        (@cmd.none, state)
      }
    UserInput(data~) =>
      if state.phase is Running(session~, id~, ..) {
        (send_input(dispatch, session, id, data), state)
      } else {
        // Typing into an exited/unopened terminal has nowhere to go.
        (@cmd.none, state)
      }
    ViewportResized(cols~, rows~) =>
      if state.phase is Running(id~, ..) {
        (send_resize(id, cols, rows), state)
      } else {
        (@cmd.none, state)
      }
    // The host starts reading the PTY as soon as it spawns, so a session's
    // first output — including the launcher's own diagnostics when the shell
    // cannot start — can reach the panel before the `terminal_open` reply
    // names its id. While opening, this panel has no other session the host
    // could be reporting, so render it; anything else is a retired session's
    // tail, which must still be acknowledged or the host's flow-control
    // window leaks and the session eventually stalls.
    Output(id~, data~, bytes~) =>
      match state.phase {
        Opening(..) => (write_output(dispatch, id, data, bytes), state)
        Running(id=running, ..) if running == id =>
          (write_output(dispatch, id, data, bytes), state)
        _ => (send_ack(id, bytes), state)
      }
    OutputRendered(id~, bytes~) => (send_ack(id, bytes), state)
    SessionExited(id~, code~) =>
      if state.phase is Running(session~, workspace~, id=running) &&
        running == id {
        (@cmd.none, { ..state, phase: Exited(session~, workspace~, code~) })
      } else {
        (@cmd.none, state)
      }
    RestartTerminal =>
      match state.phase {
        Exited(..) | Failed(..) =>
          // Respawn for the CURRENT conversation — after an exit this is
          // how a shell moves to the workspace the user is looking at.
          (
            @cmd.batch([reset_emulator(), request_terminal_mount(dispatch, ctx)]),
            { ..state, phase: Idle },
          )
        Idle | Opening(..) | Running(..) => (@cmd.none, state)
      }
  }
}
