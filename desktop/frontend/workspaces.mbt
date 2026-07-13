// The sidebar's workspace flow: `pick_workspace` opens the system folder
// chooser, `list_workspaces` reads the attached project directories back,
// and `add_workspace`/`remove_workspace` change the registry. The registry
// ops reply with the updated list, so one decoder serves them all — and
// since attaching or detaching a workspace changes which session groups
// exist, the action commands refresh the session list too.

///|
fn fetch_workspaces(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // A host without the op just reads as "no workspaces attached".
      let payload = @protocol.EmptyPayload::{  }
      let raw_reply = @interop.bridge_request("list_workspaces", payload) catch {
        _ => return
      }
      // A malformed reply is dropped like a failed op: the sidebar keeps
      // whatever list it already shows.
      let reply : @protocol.WorkspacesReply? = @interop.bridge_reply(raw_reply)
      guard reply is Some(reply) else { return }
      scheduler.add(dispatch(WorkspacesLoaded(reply.workspaces)))
    })
  })
}

///|
fn add_workspace(dispatch : @cmd.Emit[Msg], path : String) -> @cmd.Cmd {
  workspace_action(dispatch, "add_workspace", path)
}

///|
fn remove_workspace(dispatch : @cmd.Emit[Msg], path : String) -> @cmd.Cmd {
  workspace_action(dispatch, "remove_workspace", path)
}

///|
/// Open the system folder chooser and register whatever it returns. A
/// cancelled pick does nothing; a host whose platform has no chooser (the
/// op raises) falls back to the sidebar's manual path input.
fn pick_workspace(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @protocol.EmptyPayload::{  }
      let raw_reply = @interop.bridge_request("pick_workspace", payload) catch {
        _ => {
          scheduler.add(dispatch(OpenWorkspaceInput))
          return
        }
      }
      let reply : @protocol.PickWorkspaceReply? = @interop.bridge_reply(
        raw_reply,
      )
      guard reply is Some({ path: Some(path) }) && !path.is_empty() else {
        return
      }
      workspace_action_into(scheduler, dispatch, "add_workspace", path)
    })
  })
}

///|
fn workspace_action(
  dispatch : @cmd.Emit[Msg],
  op : String,
  path : String,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => workspace_action_into(scheduler, dispatch, op, path))
  })
}

///|
async fn workspace_action_into(
  scheduler : &@cmd.Scheduler,
  dispatch : @cmd.Emit[Msg],
  op : String,
  path : String,
) -> Unit noraise {
  let payload : @protocol.WorkspacePayload = { path, }
  let raw_reply = @interop.bridge_request(op, payload) catch {
    error => {
      scheduler.add(
        dispatch(WorkspaceFailed(@interop.bridge_error_text(error))),
      )
      return
    }
  }
  let reply : @protocol.WorkspacesReply? = @interop.bridge_reply(raw_reply)
  match reply {
    Some(reply) => scheduler.add(dispatch(WorkspacesLoaded(reply.workspaces)))
    None => scheduler.add(dispatch(WorkspaceFailed("malformed workspace list")))
  }
  // The registry changed, so the sidebar has a session group to gain or
  // drop; refresh the list that carries them.
  refresh_sessions_into(scheduler, dispatch)
}

///|
/// A workspace's display label: the directory's basename. The host already
/// labels session groups, but the registry itself is bare paths and a
/// workspace with no sessions yet still needs a heading.
fn workspace_label(path : String) -> String {
  // Strip trailing separators, then take everything after the last one.
  let mut end = path.length()
  while end > 0 && is_path_separator(path.code_unit_at(end - 1)) {
    end = end - 1
  }
  let mut start = end
  while start > 0 && !is_path_separator(path.code_unit_at(start - 1)) {
    start = start - 1
  }
  if end > start {
    path.view(start_offset=start, end_offset=end).to_owned()
  } else {
    path
  }
}

///|
fn is_path_separator(unit : UInt16) -> Bool {
  unit == 47 || unit == 92 // '/' or '\'
}
