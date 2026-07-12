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
      let reply = @interop.bridge_request(
        "list_workspaces",
        @js.Object::new().to_value(),
      ) catch {
        _ => return
      }
      // A malformed reply is dropped like a failed op: the sidebar keeps
      // whatever list it already shows.
      guard decode_workspaces(@interop.reply_json_text(reply))
        is Some(workspaces) else {
        return
      }
      scheduler.add(dispatch(WorkspacesLoaded(workspaces)))
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
      let reply = @interop.bridge_request(
        "pick_workspace",
        @js.Object::new().to_value(),
      ) catch {
        _ => {
          scheduler.add(dispatch(OpenWorkspaceInput))
          return
        }
      }
      let json = @json.parse(@interop.reply_json_text(reply)) catch {
        _ => return
      }
      guard json is Object(fields) &&
        fields.get("path") is Some(String(path)) &&
        !path.is_empty() else {
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
  let payload = @js.Object::new()
  payload["path"] = path
  let reply = @interop.bridge_request(op, payload.to_value()) catch {
    error => {
      scheduler.add(
        dispatch(WorkspaceFailed(@interop.bridge_error_text(error))),
      )
      return
    }
  }
  match decode_workspaces(@interop.reply_json_text(reply)) {
    Some(workspaces) => scheduler.add(dispatch(WorkspacesLoaded(workspaces)))
    None => scheduler.add(dispatch(WorkspaceFailed("malformed workspace list")))
  }
  // The registry changed, so the sidebar has a session group to gain or
  // drop; refresh the list that carries them.
  refresh_sessions_into(scheduler, dispatch)
}

///|
/// The reply's registered workspace paths; `None` only for structurally
/// unusable JSON.
fn decode_workspaces(text : String) -> Array[String]? {
  let json = @json.parse(text) catch { _ => return None }
  guard json is Object(reply) else { return None }
  guard reply.get("workspaces") is Some(Array(items)) else { return None }
  let paths : Array[String] = []
  for item in items {
    if item is String(path) && !path.is_empty() {
      paths.push(path)
    }
  }
  Some(paths)
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

// Tests for the workspace flow's pure pieces: display labels and the
// update handlers that place conversations into workspaces.

///|
test "workspace labels are the folder's basename" {
  inspect(workspace_label("/home/u/proj"), content="proj")
  inspect(workspace_label("/home/u/proj/"), content="proj")
  inspect(workspace_label("C:\\code\\app"), content="app")
  inspect(workspace_label("/"), content="/")
  inspect(workspace_label("plain"), content="plain")
}

///|
test "a workspace new chat rotates into that workspace" {
  let dispatch = test_dispatch()
  let model = { ..test_model(), workspaces: ["/home/u/proj"] }
  let (_, chosen) = update(dispatch, NewChatIn("/home/u/proj"), model)
  inspect(chosen.active_workspace, content="/home/u/proj")
  // The rotation lands like any other; the fresh conversation carries the
  // active workspace, and the next plain "New chat" stays there.
  let (_, rotated) = update(dispatch, SessionRotated("desktop-ws"), chosen)
  assert_true(rotated.active().workspace is Some(Absolute("/home/u/proj")))
  inspect(rotated.active_session, content="desktop-ws")
  inspect(rotated.active_workspace, content="/home/u/proj")
}

///|
test "a scratch rotation leaves the conversation in the default store" {
  let dispatch = test_dispatch()
  let (_, next) = update(dispatch, SessionRotated("desktop-s"), test_model())
  assert_true(next.active().workspace is None)
}

///|
test "workspaces loaded resets placements the registry no longer has" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model().replace_conversation({
      ..test_conversation(),
      workspace: Some(Absolute("/gone")),
    }),
    active_workspace: "/gone",
  }
  let (_, next) = update(dispatch, WorkspacesLoaded(["/kept"]), model)
  inspect(next.workspaces.length(), content="1")
  assert_true(next.active().workspace is None)
  inspect(next.active_workspace, content="")
  // A still-registered placement survives the same reply.
  let attached = {
    ..test_model().replace_conversation({
      ..test_conversation(),
      workspace: Some(Absolute("/kept")),
    }),
    active_workspace: "/kept",
  }
  let (_, kept) = update(dispatch, WorkspacesLoaded(["/kept"]), attached)
  assert_true(kept.active().workspace is Some(Absolute("/kept")))
  inspect(kept.active_workspace, content="/kept")
}

///|
test "opening a stored session adopts its workspace" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model(),
    sessions: [
      {
        id: "desktop-w",
        title: Some("in project"),
        workspace: "/proj",
        workspace_name: "proj",
      },
    ],
  }
  let (_, opening) = update(dispatch, OpenSession("desktop-w"), model)
  inspect(opening.active_workspace, content="/proj")
  inspect(opening.loading_session, content="desktop-w")
  let (_, loaded) = update(
    dispatch,
    SessionLoaded(session="desktop-w", items=[]),
    opening,
  )
  assert_true(loaded.active().workspace is Some(Absolute("/proj")))
}

///|
test "the picker keeps the manual input closed; its fallback opens it" {
  let dispatch = test_dispatch()
  let (_, picked) = update(dispatch, PickWorkspace, test_model())
  assert_true(picked.workspace_input is None)
  let (_, fallback) = update(dispatch, OpenWorkspaceInput, test_model())
  assert_true(fallback.workspace_input is Some(""))
}

///|
test "a workspace failure pops a toast" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    WorkspaceFailed("not a directory"),
    test_model(),
  )
  inspect(next.notifications.length(), content="1")
  inspect(
    next.notifications[0].message,
    content="Workspace error: not a directory",
  )
}

///|
test "the add-workspace input opens, edits, and submits" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, ToggleWorkspaceInput, test_model())
  assert_true(opened.workspace_input is Some(""))
  let (_, typed) = update(dispatch, WorkspaceInput("~/proj"), opened)
  assert_true(typed.workspace_input is Some("~/proj"))
  let (_, submitted) = update(dispatch, AddWorkspace, typed)
  assert_true(submitted.workspace_input is None)
  // A blank submit is a no-op that keeps the input open for a real path.
  let (_, blank) = update(dispatch, AddWorkspace, opened)
  assert_true(blank.workspace_input is Some(""))
}
