// The panel's update loop and its conversation-switch reconciliation.

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
            { ..state, phase: Opening(session=ctx.session) },
          )
        Opening(..) | Running(..) => (@cmd.none, state)
      }
    Opened(session~, id~) =>
      if state.phase is Opening(session=expected) && expected == session {
        (wire_session(id), { ..state, phase: Running(session~, id~) })
      } else {
        // The conversation switched while the open was in flight; the
        // session belongs to nobody now, so retire it on the host.
        (send_close(id), state)
      }
    OpenFailed(session~, message~) =>
      if state.phase.session() is Some(current) && current == session {
        (@cmd.none, { ..state, phase: Failed(session~, message~) })
      } else {
        (@cmd.none, state)
      }
    UserInput(data~) =>
      if state.phase is Running(session~, id~) {
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
    Output(id~, data~) =>
      if state.phase is Running(id=running, ..) && running == id {
        (write_output(dispatch, id, data), state)
      } else {
        (@cmd.none, state)
      }
    OutputRendered(id~, bytes~) => (send_ack(id, bytes), state)
    SessionExited(id~, code~) =>
      if state.phase is Running(session~, id=running) && running == id {
        (@cmd.none, { ..state, phase: Exited(session~, code~) })
      } else {
        (@cmd.none, state)
      }
    RestartTerminal =>
      match state.phase {
        Exited(..) | Failed(..) =>
          (
            @cmd.batch([reset_emulator(), request_terminal_mount(dispatch, ctx)]),
            { ..state, phase: Idle },
          )
        Idle | Opening(..) | Running(..) => (@cmd.none, state)
      }
  }
}

///|
/// Reconcile the panel with the active conversation after every message
/// (the main package calls this like `@fileeditor.sync`): a session opened
/// for another conversation is retired — closed on the host, its screen
/// blanked — and an open panel respawns for the new conversation.
pub fn sync(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
) -> (State, @cmd.Cmd) {
  guard state.phase.session() is Some(session) else {
    return (state, @cmd.none)
  }
  if session == ctx.session {
    return (state, @cmd.none)
  }
  let cmds : Array[@cmd.Cmd] = []
  if state.phase is Running(id~, ..) {
    cmds.push(send_close(id))
  }
  cmds.push(reset_emulator())
  if state.open {
    cmds.push(request_terminal_mount(dispatch, ctx))
  }
  ({ ..state, phase: Idle }, @cmd.batch(cmds))
}
