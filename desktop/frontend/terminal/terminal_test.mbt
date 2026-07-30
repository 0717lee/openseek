///|
test "Windows workspace paths use their final component as the tab label" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let ctx : @terminal.Ctx = {
    session: "windows-workspace",
    workspace: Some(@pathx.Absolute("C:\\Users\\alice\\project")),
    dark_mode: false,
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
    session: "exit-race",
    workspace: Some(@pathx.Absolute("/work/project")),
    dark_mode: false,
  }
  let (_, opening) = @terminal.update(
    emit,
    @terminal.ToggleTerminal,
    @terminal.State::empty(),
    ctx,
  )
  let (_, exited) = @terminal.update(
    emit,
    @terminal.SessionExited(id=42, code=0),
    opening,
    ctx,
  )
  assert_true(exited.exited_before_open.contains(42))
  let (_, replied) = @terminal.update(
    emit,
    @terminal.Opened(key=1, id=42),
    exited,
    ctx,
  )
  assert_true(replied.tabs.is_empty())
  assert_true(!replied.exited_before_open.contains(42))
  assert_true(!replied.open)
}

///|
test "sync records color-scheme changes even when the shown tab is unchanged" {
  let emit : @cmd.Emit[@terminal.Msg] = @cmd.Emit(_ => @cmd.none)
  let light_ctx : @terminal.Ctx = {
    session: "theme",
    workspace: None,
    dark_mode: false,
  }
  let (light, _) = @terminal.sync(emit, @terminal.State::empty(), light_ctx)
  assert_true(light.shown is None)
  assert_true(light.synced_dark_mode is Some(false))
  let (dark, _) = @terminal.sync(emit, light, { ..light_ctx, dark_mode: true })
  assert_true(dark.shown is None)
  assert_true(dark.synced_dark_mode is Some(true))
}
