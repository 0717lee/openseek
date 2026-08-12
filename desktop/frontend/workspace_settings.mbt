// Per-workspace desktop settings, mirrored from the workspace's own
// `.openseek/settings.json` on its host. One setting today: whether a NEW
// conversation starts in a fresh bound git worktree instead of the
// workspace root. The mirror refreshes with the project list and is
// replaced wholesale by the `workspace.settings_changed` broadcast; the
// settings page edits it through `workspace.settings_set`, and the
// composer chip stays a per-conversation override that never writes here.

///|
/// One project's settings mirror, keyed like `ProjectWorktrees` and fenced
/// by the same per-project generation rule: a reply carrying an older token
/// is stale for that project alone.
priv struct ProjectSettings {
  project : @common.Uri
  worktree_mode : Bool
  generation : Int
} derive(Eq)

///|
/// The one open project-row "…" menu (settings, detach).
priv struct ProjectMenu {
  channel : @interop.ChannelId
  project : @common.Uri
} derive(Eq, Debug)

///|
fn fetch_workspace_settings(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  workspace : @common.Uri,
  connection_generation : Int,
  request_generation : Int,
) -> @cmd.Cmd {
  guard @resource.belongs_to(workspace, channel) else { return @cmd.none }
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // A host without the op (or a failed read) dispatches nothing: the
      // workspace keeps the Local default until a later fetch answers.
      // Unlike a worktree list, nothing downstream is blocked on it.
      let reply : @protocol.WorkspaceSettingsPayload = @interop.bridge_request(
        channel,
        @commands.workspace_settings_get,
        { workspace: workspace.path },
      ) catch {
        _ => return
      }
      scheduler.add(
        dispatch(
          WorkspaceSettingsLoaded(
            workspace~,
            worktree_mode=reply.worktree_mode,
            connection_generation~,
            request_generation~,
          ),
        ),
      )
    })
  })
}

///|
fn save_workspace_settings(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  workspace : @common.Uri,
  worktree_mode : Bool,
) -> @cmd.Cmd {
  guard @resource.belongs_to(workspace, channel) else { return @cmd.none }
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // Success needs no dispatch: the committed state reaches every client
      // (this one included) as the canonical `workspace.settings_changed`
      // broadcast from the store's commit seam.
      let _ : @protocol.WorkspaceSettingsPayload = @interop.bridge_request(
        channel,
        @commands.workspace_settings_set,
        { workspace: workspace.path, worktree_mode },
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              WorkspaceSettingsSaveFailed(
                workspace~,
                message=@interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
    })
  })
}

///|
/// The `workspace.settings_changed` notification: the workspace it belongs
/// to plus its canonical post-commit state.
fn workspace_settings_changed_msg(
  channel : @interop.ChannelId,
  payload : @protocol.WorkspaceSettingsPayload,
) -> DeviceMsg? {
  guard @resource.of_path(channel, payload.workspace) is Some(workspace) else {
    return None
  }
  Some(
    WorkspaceSettingsChanged(workspace~, worktree_mode=payload.worktree_mode),
  )
}

///|
fn DeviceState::with_workspace_settings(
  self : DeviceState,
  project : @common.Uri,
  worktree_mode : Bool,
  generation~ : Int,
) -> DeviceState {
  let rows = self.workspace_settings.filter(row => row.project != project)
  rows.push({ project, worktree_mode, generation })
  { ..self, workspace_settings: rows }
}

///|
/// The loaded settings row for one project; `None` until the first
/// authoritative read or broadcast for it arrives on this connection.
fn DeviceState::workspace_settings_row(
  self : DeviceState,
  project : @common.Uri,
) -> ProjectSettings? {
  for row in self.workspace_settings {
    if row.project == project {
      return Some(row)
    }
  }
  None
}

///|
/// The token one project's settings were last applied under; a reply
/// carrying an older token is stale for that project alone.
fn DeviceState::workspace_settings_generation(
  self : DeviceState,
  project : @common.Uri,
) -> Int {
  match self.workspace_settings_row(project) {
    Some(row) => row.generation
    None => -1
  }
}

///|
/// The launch-mode default copied into a new conversation in `project`.
/// Scratch chats (`None`) and workspaces whose settings have not loaded
/// stay on the safe Local default.
fn DeviceState::default_worktree_mode(
  self : DeviceState,
  project : @common.Uri?,
) -> Bool {
  if project is Some(project) &&
    self.workspace_settings_row(project) is Some(row) {
    row.worktree_mode
  } else {
    false
  }
}

///|
fn Model::default_worktree_mode(
  self : Model,
  channel : @interop.ChannelId,
  project : @common.Uri?,
) -> Bool {
  if self.device_state(channel) is Some(dev) {
    dev.default_worktree_mode(project)
  } else {
    false
  }
}

///|
/// Spend one workspace's row of the retired page-local preference: drop it
/// from the model and from the stored list (removal is how that store
/// spells Local). A workspace with no row is a no-op.
fn forget_legacy_default_mode(
  model : Model,
  workspace : @common.Uri,
) -> (@cmd.Cmd, Model) {
  guard model.legacy_workspace_default_mode.worktrees.contains(
    workspace.to_string(),
  ) else {
    return (@cmd.none, model)
  }
  (
    WorkspaceDefaultMode::save(workspace, false),
    {
      ..model,
      legacy_workspace_default_mode: model.legacy_workspace_default_mode.with_mode(
        workspace, false,
      ),
    },
  )
}

// Tests below cover the settings mirror's staleness fences, the page's
// optimistic write, the one-shot legacy migration, and the "…" menu and
// settings-page navigation that ride on the mirror.

///|
test "a settings reply lands once and an older token cannot roll it back" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  let (_, loaded) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=true,
      connection_generation=0,
      request_generation=1,
    ),
    test_model(),
  )
  assert_true(loaded.default_worktree_mode(Local, Some(workspace)))
  // An older reply for the same workspace is stale; one for a sibling
  // workspace still lands (the fence is per project).
  let (_, stale) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=false,
      connection_generation=0,
      request_generation=1,
    ),
    loaded,
  )
  assert_true(stale.default_worktree_mode(Local, Some(workspace)))
  let sibling = @interop.ChannelId::Local.test_resource("/other")
  let (_, both) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace=sibling,
      worktree_mode=true,
      connection_generation=0,
      request_generation=1,
    ),
    stale,
  )
  assert_true(both.default_worktree_mode(Local, Some(sibling)))
  // A dead connection's reply is rejected outright.
  let (_, dead) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=false,
      connection_generation=7,
      request_generation=9,
    ),
    both,
  )
  assert_true(dead.default_worktree_mode(Local, Some(workspace)))
}

///|
test "a settings commit broadcast supersedes list replies" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  let (_, changed) = update_dev(
    dispatch,
    WorkspaceSettingsChanged(workspace~, worktree_mode=true),
    test_model(),
  )
  assert_true(changed.default_worktree_mode(Local, Some(workspace)))
  inspect(changed.dev().workspace_settings_request_generation, content="1")
  // A list reply issued before the commit answers on an older token.
  let (_, stale) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=false,
      connection_generation=0,
      request_generation=1,
    ),
    changed,
  )
  assert_true(stale.default_worktree_mode(Local, Some(workspace)))
}

///|
test "the settings page select applies optimistically" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  // The state the adopt fan-out leaves behind: the mint spent one token on
  // the round and this workspace's reply landed under it.
  let fetched = test_model().with_dev(dev => {
    ..dev,
    workspace_settings_request_generation: 1,
  })
  let (_, loaded) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=false,
      connection_generation=0,
      request_generation=1,
    ),
    fetched,
  )
  let (_, chosen) = update(
    dispatch,
    WorkspaceDefaultModeChosen(Local, workspace, "worktree"),
    loaded,
  )
  assert_true(chosen.default_worktree_mode(Local, Some(workspace)))
  // The optimistic write spent a fresh token, so a pre-edit reply still in
  // flight cannot flip the select back under the user.
  let (_, raced) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=false,
      connection_generation=0,
      request_generation=1,
    ),
    chosen,
  )
  assert_true(raced.default_worktree_mode(Local, Some(workspace)))
  let (_, back) = update(
    dispatch,
    WorkspaceDefaultModeChosen(Local, workspace, "local"),
    chosen,
  )
  assert_false(back.default_worktree_mode(Local, Some(workspace)))
}

///|
test "a failed save pops a toast and re-reads under a fresh token" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  let (_, chosen) = update(
    dispatch,
    WorkspaceDefaultModeChosen(Local, workspace, "worktree"),
    test_model(),
  )
  let minted = chosen.dev().workspace_settings_request_generation
  let (_, failed) = update_dev(
    dispatch,
    WorkspaceSettingsSaveFailed(workspace~, message="disk full"),
    chosen,
  )
  inspect(failed.notifications.length(), content="1")
  assert_true(failed.notifications[0].message.contains("disk full"))
  inspect(
    failed.dev().workspace_settings_request_generation,
    content="\{minted + 1}",
  )
  // The refetch it issued may answer on the fresh token and correct the
  // optimistic value.
  let (_, corrected) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=false,
      connection_generation=0,
      request_generation=minted + 1,
    ),
    failed,
  )
  assert_false(corrected.default_worktree_mode(Local, Some(workspace)))
}

///|
test "the retired page-local default migrates up exactly once" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  let legacy = {
    ..test_model(),
    legacy_workspace_default_mode: WorkspaceDefaultMode::{ worktrees: [] }.with_mode(
      workspace, true,
    ),
  }
  // Disk says Local by absence, the legacy row says Worktree: the read
  // consumes the row and pushes the mode up as a real settings write,
  // applied optimistically like the page's own select.
  let (_, migrated) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=false,
      connection_generation=0,
      request_generation=1,
    ),
    legacy,
  )
  assert_true(migrated.default_worktree_mode(Local, Some(workspace)))
  assert_true(migrated.legacy_workspace_default_mode.worktrees.is_empty())
  // A workspace whose disk already says Worktree only spends the row.
  let (_, spent) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode=true,
      connection_generation=0,
      request_generation=1,
    ),
    legacy,
  )
  assert_true(spent.default_worktree_mode(Local, Some(workspace)))
  assert_true(spent.legacy_workspace_default_mode.worktrees.is_empty())
  // Another client's commit broadcast is just as authoritative: after it,
  // a later Local read must not re-fire the migration.
  let (_, broadcast) = update_dev(
    dispatch,
    WorkspaceSettingsChanged(workspace~, worktree_mode=true),
    legacy,
  )
  assert_true(broadcast.legacy_workspace_default_mode.worktrees.is_empty())
  // A different workspace's row stays for its own workspace's first read.
  let other = @interop.ChannelId::Local.test_resource("/other")
  let (_, unrelated) = update_dev(
    dispatch,
    WorkspaceSettingsLoaded(
      workspace=other,
      worktree_mode=false,
      connection_generation=0,
      request_generation=1,
    ),
    legacy,
  )
  assert_true(
    unrelated.legacy_workspace_default_mode.worktrees.contains(
      workspace.to_string(),
    ),
  )
}

///|
test "settings commit decoder carries the workspace identity" {
  guard bridge_msg(
      @interop.ChannelId::Local,
      @protocol.Notification::WorkspaceSettingsChanged({
        workspace: "/proj",
        worktree_mode: true,
      }),
    )
    is Some(FromDevice(_, WorkspaceSettingsChanged(workspace~, worktree_mode~))) else {
    fail("expected a workspace settings change")
  }
  inspect(workspace.path, content="/proj")
  assert_true(worktree_mode)
}

///|
test "the project menu toggles, navigates to the settings page, and detaches" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  let (_, opened) = update(
    dispatch,
    ToggleProjectMenu(Local, workspace),
    test_model(),
  )
  assert_eq(opened.project_menu, Some({ channel: Local, project: workspace }))
  // The same click closes; a different row's click moves the menu.
  let (_, closed) = update(
    dispatch,
    ToggleProjectMenu(Local, workspace),
    opened,
  )
  assert_true(closed.project_menu is None)
  let other = @interop.ChannelId::Local.test_resource("/other")
  let (_, moved) = update(dispatch, ToggleProjectMenu(Local, other), opened)
  assert_eq(moved.project_menu, Some({ channel: Local, project: other }))
  let (_, dismissed) = update(dispatch, CloseProjectMenu, moved)
  assert_true(dismissed.project_menu is None)
  // The settings item opens the page and takes the menu with it.
  let (_, page) = update(
    dispatch,
    OpenWorkspaceSettings(Local, workspace),
    opened,
  )
  assert_true(
    page.screen == WorkspaceSettings(channel=Local, workspace~) &&
    page.project_menu is None,
  )
  // Detach closes the menu with the click that acted from it.
  let (_, detached) = update(dispatch, RemoveProject(Local, workspace), opened)
  assert_true(detached.project_menu is None)
}

///|
test "detaching a workspace closes its settings page and menu" {
  let dispatch = test_dispatch()
  let gone = @interop.ChannelId::Local.test_resource("/gone")
  let kept = @interop.ChannelId::Local.test_resource("/kept")
  let model = {
    ..test_model().with_dev(dev => { ..dev, projects: [gone, kept] }),
    screen: WorkspaceSettings(channel=Local, workspace=gone),
    project_menu: Some({ channel: Local, project: gone }),
  }
  let (_, adopted) = update_dev(dispatch, ProjectsChanged([kept]), model)
  assert_true(adopted.screen is Chat)
  assert_true(adopted.project_menu is None)
  // A snapshot that retains the workspace leaves both alone.
  let staying = {
    ..test_model().with_dev(dev => { ..dev, projects: [kept] }),
    screen: WorkspaceSettings(channel=Local, workspace=kept),
    project_menu: Some({ channel: Local, project: kept }),
  }
  let (_, retained) = update_dev(dispatch, ProjectsChanged([kept]), staying)
  assert_true(
    retained.screen == WorkspaceSettings(channel=Local, workspace=kept),
  )
  assert_eq(retained.project_menu, Some({ channel: Local, project: kept }))
}
