///|
test "Windows workspace paths use their final component as the tab label" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let ctx : @terminal.Ctx = {
    channel: @interop.ChannelId::Local,
    session: "windows-workspace",
    workspace: Some(@pathx.Absolute("C:\\Users\\alice\\project")),
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
    is @terminal.Project(@interop.ChannelId::Local, "/work/project"),
  )
  assert_true(tab.id is Some(1))
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
        workspace: @terminal.Project(local_channel, "/local"),
        workspace_label: "local",
        session: "local",
        workspace_path: Some(@pathx.Absolute("/local")),
        status: @terminal.TabRunning,
      },
      {
        key: 2,
        id: Some(1),
        workspace: @terminal.Project(remote, "/remote"),
        workspace_label: "remote",
        session: "remote",
        workspace_path: Some(@pathx.Absolute("/remote")),
        status: @terminal.TabRunning,
      },
    ],
    active: [
      (@terminal.Project(local_channel, "/local"), 1),
      (@terminal.Project(remote, "/remote"), 2),
    ],
    shown: Some(2),
    exited_before_open: [(remote, 9), (local_channel, 9)],
    synced_dark_mode: Some(false),
  }
  let (_, disconnected) = @terminal.disconnect(state, remote)
  inspect(disconnected.tabs.length(), content="1")
  assert_true(
    disconnected.tabs[0].workspace
    is @terminal.Project(@interop.ChannelId::Local, "/local"),
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
    is @terminal.Scratch(@interop.ChannelId::Remote("device-1"), "reconnect"),
  )
}
