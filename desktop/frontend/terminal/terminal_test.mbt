///|
test "Windows workspace paths use their final component as the tab label" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Local,
    session: "windows-workspace",
    workspace: Some(@pathx.Absolute("C:\\Users\\alice\\project")),
    worktree: None,
    dark_mode: false,
    connected: true,
  }
  let (_, state) = @terminal.update(
    emit,
    @terminal.ToggleTerminal,
    @terminal.State::empty(),
    ctx,
  )
  guard state.tabs.get(0) is Some(tab) else {
    fail("terminal tab was not opened")
  }
  assert_eq(tab.workspace_label, "project")
}

///|
test "an exit before the open reply cannot revive a dead terminal" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Local,
    session: "exit-race",
    workspace: Some(@pathx.Absolute("/work/project")),
    worktree: None,
    dark_mode: false,
    connected: true,
  }
  let (_, opening) = @terminal.update(
    emit,
    @terminal.ToggleTerminal,
    @terminal.State::empty(),
    ctx,
  )
  let (_, exited) = @terminal.update(
    emit,
    @terminal.SessionExited(channel=@interop.ChannelId::Local, id=42, code=0),
    opening,
    ctx,
  )
  assert_true(
    exited.exited_before_open.contains((@interop.ChannelId::Local, 42)),
  )
  let (_, replied) = @terminal.update(
    emit,
    @terminal.Opened(channel=@interop.ChannelId::Local, key=1, id=42),
    exited,
    ctx,
  )
  assert_true(replied.tabs.is_empty())
  assert_true(
    !replied.exited_before_open.contains((@interop.ChannelId::Local, 42)),
  )
  assert_true(!replied.open)
}

///|
test "sync records color-scheme changes even when the shown tab is unchanged" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let light_ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Local,
    session: "theme",
    workspace: None,
    worktree: None,
    dark_mode: false,
    connected: true,
  }
  let (light, _) = @terminal.sync(emit, @terminal.State::empty(), light_ctx)
  assert_true(light.shown is None)
  assert_true(light.synced_dark_mode is Some(false))
  let (dark, _) = @terminal.sync(emit, light, { ..light_ctx, dark_mode: true })
  assert_true(dark.shown is None)
  assert_true(dark.synced_dark_mode is Some(true))
}

///|
test "output acknowledgement messages leave terminal state unchanged" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Local,
    session: "ack-purity",
    workspace: None,
    worktree: None,
    dark_mode: false,
    connected: true,
  }
  let state = @terminal.State::empty()
  let (_, first) = @terminal.update(
    emit,
    @terminal.OutputRendered(
      channel=@interop.ChannelId::Local,
      id=7,
      sequence=11,
    ),
    state,
    ctx,
  )
  let (_, second) = @terminal.update(
    emit,
    @terminal.OutputRendered(
      channel=@interop.ChannelId::Local,
      id=7,
      sequence=11,
    ),
    state,
    ctx,
  )
  assert_true(first == state)
  assert_true(second == state)
}

///|
test "same-numbered terminal ids on different devices stay isolated" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let local_ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Local,
    session: "shared-session",
    workspace: Some(@pathx.Absolute("/work/project")),
    worktree: None,
    dark_mode: false,
    connected: true,
  }
  let remote : @interop.ChannelId = Remote("device-1")
  let remote_ctx : @terminal.Ctx = { ..local_ctx, channel: remote }
  let (_, local_opening) = @terminal.update(
    emit,
    @terminal.ToggleTerminal,
    @terminal.State::empty(),
    local_ctx,
  )
  let (_, local_running) = @terminal.update(
    emit,
    @terminal.Opened(channel=@interop.ChannelId::Local, key=1, id=1),
    local_opening,
    local_ctx,
  )
  let (_, both_opening) = @terminal.update(
    emit,
    @terminal.NewTerminal,
    local_running,
    remote_ctx,
  )
  let (_, both_running) = @terminal.update(
    emit,
    @terminal.Opened(channel=remote, key=2, id=1),
    both_opening,
    remote_ctx,
  )
  inspect(both_running.tabs.length(), content="2")
  let (_, remote_exited) = @terminal.update(
    emit,
    @terminal.SessionExited(channel=remote, id=1, code=0),
    both_running,
    remote_ctx,
  )
  inspect(remote_exited.tabs.length(), content="1")
  guard remote_exited.tabs.get(0) is Some(tab) else {
    fail("local terminal was not preserved")
  }
  assert_true(
    tab.workspace
    is @terminal.Project(
      channel=@interop.ChannelId::Local,
      workspace="/work/project",
      worktree=None
    ),
  )
  assert_true(tab.id is Some(1))
}

///|
test "conversations in different checkouts of one project do not share shells" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  // Two conversations, one project. The bound one's terminal is rooted in
  // its worktree by the host, so handing that shell to the Local one would
  // run its commands in a checkout the user is not looking at.
  let local_ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Local,
    session: "s-local",
    workspace: Some(@pathx.Absolute("/work/project")),
    worktree: None,
    dark_mode: false,
    connected: true,
  }
  let worktree_ctx : @terminal.Ctx = {
    ..local_ctx,
    session: "s-wt",
    worktree: Some("wt-1"),
  }
  let (_, in_worktree) = @terminal.update(
    emit,
    @terminal.ToggleTerminal,
    @terminal.State::empty(),
    worktree_ctx,
  )
  guard in_worktree.tabs.get(0) is Some(opened) else {
    fail("worktree terminal was not opened")
  }
  // The worktree's own group, labelled so the tab strip tells the two apart.
  assert_true(
    opened.workspace
    is @terminal.Project(
      channel=@interop.ChannelId::Local,
      workspace="/work/project",
      worktree=Some("wt-1")
    ),
  )
  assert_eq(opened.workspace_label, "project/wt-1")
  // Switching to the Local conversation finds no shell of its own, so sync
  // opens one. Sharing the worktree's group would have reused that shell
  // instead — the whole defect — and left the count at one.
  let (in_main, _) = @terminal.sync(emit, in_worktree, local_ctx)
  inspect(in_main.tabs.length(), content="2")
  guard in_main.tabs.get(1) is Some(main_tab) else {
    fail("the local conversation got no shell of its own")
  }
  assert_eq(main_tab.workspace_label, "project")
  assert_true(main_tab.workspace != opened.workspace)
  // A second conversation in the SAME checkout still shares, which is what
  // grouping is for: sync finds its group's tab and opens nothing.
  let (sibling, _) = @terminal.sync(emit, in_main, {
    ..local_ctx,
    session: "s-local-2",
  })
  inspect(sibling.tabs.length(), content="2")
  // And returning to the worktree conversation still finds its own.
  let (back, _) = @terminal.sync(emit, sibling, worktree_ctx)
  inspect(back.tabs.length(), content="2")
}

///|
test "a disconnected channel retires only its terminal tabs" {
  let local_channel : @interop.ChannelId = @interop.ChannelId::Local
  let remote : @interop.ChannelId = Remote("device-1")
  let state : @terminal.State = {
    open: true,
    next_key: 3,
    tabs: [
      {
        key: 1,
        id: Some(1),
        workspace: @terminal.Project(
          channel=local_channel,
          workspace="/local",
          worktree=None,
        ),
        workspace_label: "local",
        session: "local",
        workspace_path: Some(@pathx.Absolute("/local")),
        status: @terminal.TabRunning,
      },
      {
        key: 2,
        id: Some(1),
        workspace: @terminal.Project(
          channel=remote,
          workspace="/remote",
          worktree=None,
        ),
        workspace_label: "remote",
        session: "remote",
        workspace_path: Some(@pathx.Absolute("/remote")),
        status: @terminal.TabRunning,
      },
    ],
    active: [
      (
        @terminal.Project(
          channel=local_channel,
          workspace="/local",
          worktree=None,
        ),
        1,
      ),
      (@terminal.Project(channel=remote, workspace="/remote", worktree=None), 2),
    ],
    shown: Some(2),
    exited_before_open: [(remote, 9), (local_channel, 9)],
    synced_dark_mode: Some(false),
  }
  let (_, disconnected) = @terminal.disconnect(state, remote)
  inspect(disconnected.tabs.length(), content="1")
  assert_true(
    disconnected.tabs[0].workspace
    is @terminal.Project(
      channel=@interop.ChannelId::Local,
      workspace="/local",
      worktree=None
    ),
  )
  assert_true(disconnected.shown is None)
  assert_true(disconnected.exited_before_open == [(local_channel, 9)])
}

///|
test "an open panel waits for a reconnected channel before replacing its PTY" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let disconnected_ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Remote("device-1"),
    session: "reconnect",
    workspace: None,
    worktree: None,
    dark_mode: false,
    connected: false,
  }
  let (_, opened) = @terminal.update(
    emit,
    @terminal.ToggleTerminal,
    @terminal.State::empty(),
    disconnected_ctx,
  )
  assert_true(opened.open)
  assert_true(opened.tabs.is_empty())
  let (still_waiting, _) = @terminal.sync(emit, opened, disconnected_ctx)
  assert_true(still_waiting.tabs.is_empty())
  let (reconnected, _) = @terminal.sync(emit, still_waiting, {
    ..disconnected_ctx,
    connected: true,
  })
  inspect(reconnected.tabs.length(), content="1")
  assert_true(
    reconnected.tabs[0].workspace
    is @terminal.Scratch(
      channel=@interop.ChannelId::Remote("device-1"),
      session="reconnect"
    ),
  )
}
