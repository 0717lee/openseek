// The panel's update loop. Two deliberate properties:
//
// Shells OUTLIVE conversation switches. Their running jobs, history, and
// working directories are the user's work, so nothing here retires a
// session because the active conversation changed — switching workspaces
// only changes which tab group the panel shows, and each group's shells
// keep running (and rendering into their hidden emulators) meanwhile.
//
// A tab never migrates: it is bound at creation to the conversation and
// workspace it was opened for, and a restart after its shell exits reuses
// that binding. Sessions end when their child exits, when the user closes
// the tab or restarts it, or when the webview disconnects (the host tears
// its task group down).

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
/// Create a tab bound to the active conversation's workspace and mount its
/// emulator (whose ready report spawns the session).
fn open_new_tab(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
) -> (@cmd.Cmd, State) {
  let key = state.next_key
  let group = workspace_key(ctx)
  let tab : Tab = {
    key,
    id: None,
    workspace: group,
    workspace_label: workspace_label(ctx),
    session: ctx.session,
    workspace_path: ctx.workspace,
    status: TabOpening,
  }
  let state = { ..state, next_key: key + 1, tabs: state.tabs + [tab] }
  (mount_tab(dispatch, key, ctx.dark_mode), state.remember_active(group, key))
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
        // Hide only — every shell keeps running for the panel's return.
        (@cmd.none, { ..state, open: false })
      } else {
        match state.active_tab(ctx) {
          // This workspace group already has shells: reveal its tab.
          Some(tab) => (activate_tab(tab.key), { ..state, open: true })
          // First open in this workspace: start its first shell.
          None => {
            let (cmd, state) = open_new_tab(dispatch, state, ctx)
            (cmd, { ..state, open: true })
          }
        }
      }
    NewTerminal => open_new_tab(dispatch, state, ctx)
    TabSelected(key~) => {
      guard state.tab_by_key(key) is Some(tab) else {
        return (@cmd.none, state)
      }
      (activate_tab(key), state.remember_active(tab.workspace, key))
    }
    TabClosed(key~) => {
      guard state.tab_by_key(key) is Some(tab) else {
        return (@cmd.none, state)
      }
      let cmds = [dispose_tab(key)]
      if tab.id is Some(id) {
        cmds.push(send_close(id))
      }
      let state = {
        ..state,
        tabs: state.tabs.filter(entry => entry.key != key),
        active: state.active.filter(entry => entry.1 != key),
      }
      // Reveal the group's fallback tab, if the closed one was on screen.
      if state.active_tab(ctx) is Some(next) {
        cmds.push(activate_tab(next.key))
      }
      (@cmd.batch(cmds), state)
    }
    EmulatorReady(key~, cols~, rows~) => {
      // Ready reports are idempotent (mount_tab re-reports on reveal); only
      // a tab still waiting for its first session spawns one.
      guard state.tab_by_key(key) is Some(tab) else {
        return (@cmd.none, state)
      }
      if tab.status is TabOpening && tab.id is None {
        (
          open_session(
            dispatch,
            key,
            tab.session,
            tab.workspace_path,
            cols,
            rows,
          ),
          state,
        )
      } else {
        (@cmd.none, state)
      }
    }
    Opened(key~, id~) =>
      if state.tab_by_key(key) is Some(tab) && tab.status is TabOpening {
        (
          @cmd.batch([flush_pending(dispatch, key, id), activate_tab(key)]),
          state.replace_tab({ ..tab, id: Some(id), status: TabRunning }),
        )
      } else {
        // The tab was closed while the open was in flight; the session
        // belongs to nobody, so retire it on the host.
        (@cmd.batch([send_close(id), drop_pending(dispatch, id)]), state)
      }
    OpenFailed(key~, message~) =>
      if state.tab_by_key(key) is Some(tab) {
        (@cmd.none, state.replace_tab({ ..tab, status: TabFailed(message~) }))
      } else {
        (@cmd.none, state)
      }
    UserInput(key~, data~) =>
      if state.tab_by_key(key) is Some(tab) &&
        tab.status is TabRunning &&
        tab.id is Some(id) {
        (send_input(dispatch, key, id, data), state)
      } else {
        // Typing into an exited/unopened terminal has nowhere to go.
        (@cmd.none, state)
      }
    ViewportResized(key~, cols~, rows~) =>
      if state.tab_by_key(key) is Some(tab) &&
        tab.status is TabRunning &&
        tab.id is Some(id) {
        (send_resize(id, cols, rows), state)
      } else {
        (@cmd.none, state)
      }
    Output(id~, data~, bytes~) =>
      match state.tab_by_id(id) {
        Some(tab) => (write_to_tab(dispatch, tab.key, id, data, bytes), state)
        // No tab claims this session yet. While an open is in flight this
        // is almost certainly its first output racing the reply, so hold
        // the chunk for the claim; otherwise acknowledge and drop it (an
        // unacknowledged chunk leaks the host's flow-control window).
        None =>
          if state.tabs.iter().any(tab => tab.status is TabOpening) {
            (buffer_pending(id, data, bytes), state)
          } else {
            (send_ack(id, bytes), state)
          }
      }
    OutputRendered(id~, bytes~) => (send_ack(id, bytes), state)
    SessionExited(id~, code~) =>
      match state.tab_by_id(id) {
        Some(tab) =>
          (@cmd.none, state.replace_tab({ ..tab, status: TabExited(code~) }))
        None => (drop_pending(dispatch, id), state)
      }
    RestartTab(key~) => {
      guard state.tab_by_key(key) is Some(tab) else {
        return (@cmd.none, state)
      }
      match tab.status {
        TabExited(..) | TabFailed(..) =>
          // Same binding, fresh shell: the tab stays in its workspace.
          (
            @cmd.batch([reset_tab(key), mount_tab(dispatch, key, ctx.dark_mode)]),
            state.replace_tab({ ..tab, id: None, status: TabOpening }),
          )
        TabOpening | TabRunning => (@cmd.none, state)
      }
    }
  }
}
