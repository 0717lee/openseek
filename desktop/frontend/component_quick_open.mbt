// Shell half of unified Quick Open. The palette owns its query, rows, and
// Host search cache; this file owns the three things that are the shell's:
// which conversation and editor tabs it searches, whether it may open at all,
// and where an accepted row lands.

///|
/// Project the focused conversation and its open editor tabs into the palette.
/// The projection is read-only; the opaque palette state itself is stored once
/// in the application Model. The checkout is passed in because the palette
/// only ever exists for one that is on screen.
fn Model::quick_open_input(
  self : Model,
  active : ActiveCheckout,
) -> @quick_open.Input {
  @quick_open.Input(
    owner=active.owner,
    root=active.placement.bind(placement => placement.checkout_root()),
    open_files=self.live_editor_files(),
    active_file=@dock.active_file(self.dock),
  )
}

///|
/// The screen that owns an accepted Quick Open row. External conversation
/// pages must stay selected so `open_editor_at` resolves the relative result
/// against the checkout that the palette searched. Pages without an editor
/// return to the ordinary OpenSeek conversation.
fn Screen::after_quick_open_pick(self : Screen) -> Screen {
  match self {
    Codex => Codex
    Dsh => Dsh
    Chat | Skills | Settings | WorkspaceSettings(..) => Chat
  }
}

///|
/// Answer the shortcut. Whether the palette may appear is a shell question:
/// another modal or a lost bridge already owns the screen, and the palette
/// would render over it with no way back. The topbar's app launcher is not an
/// exclusion but a casualty — the palette's backdrop covers it, so it closes.
fn open_quick_open(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  provider : @quick_open.Provider,
) -> (@cmd.Cmd, Model) {
  guard model.project_picker is None &&
    model.archive_confirm is None &&
    model.archived_delete_confirm is None &&
    model.dsh_archive_confirm is None &&
    !(model.update_ux is ConfirmingRestart(..)) &&
    !(model.bridge_state() is BridgeLost(_)) &&
    model.active_checkout() is Some(active) else {
    return (@cmd.none, model)
  }
  let (cmd, quick_open) = model.quick_open.open(
    dispatch.map(msg => QuickOpen(msg)),
    model.quick_open_input(active),
    provider,
  )
  (cmd, { ..model, quick_open, launcher: { ..model.launcher, open: false } })
}

///|
/// Route one palette message and, when it accepted a row, open that row in the
/// same root transition. Keeping both halves in one message is what lets panel
/// reconciliation see a single `opens_file_before_panel_reconciliation` pass
/// rather than a close followed by an open.
fn update_quick_open(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  msg : @quick_open.Msg,
) -> (@cmd.Cmd, Model) {
  // The palette searches one checkout. With none on screen it has no owner to
  // answer for, so it closes rather than resolving the message against a
  // conversation or task that is gone.
  guard model.active_checkout() is Some(active) else {
    let (cmd, quick_open) = model.quick_open.close()
    return (cmd, { ..model, quick_open, })
  }
  let (cmd, quick_open, accepted) = model.quick_open.handle(
    dispatch.map(msg => QuickOpen(msg)),
    msg,
    model.quick_open_input(active),
  )
  let model = { ..model, quick_open, }
  guard accepted is Some(target) else { return (cmd, model) }
  let screen = model.screen.after_quick_open_pick()
  let (open_cmd, model) = open_editor_at(
    dispatch,
    { ..model, screen, },
    target.path,
    target.range,
  )
  (@cmd.batch([cmd, open_cmd]), model)
}

///|
test "Quick Open keeps the checkout-owning conversation screen" {
  assert_true(Screen::Codex.after_quick_open_pick() is Screen::Codex)
  assert_true(Screen::Dsh.after_quick_open_pick() is Screen::Dsh)
  assert_true(Screen::Chat.after_quick_open_pick() is Screen::Chat)
  assert_true(Screen::Skills.after_quick_open_pick() is Screen::Chat)
  assert_true(Screen::Settings.after_quick_open_pick() is Screen::Chat)
  assert_true(
    Screen::WorkspaceSettings(
      channel=@interop.ChannelId::Local,
      workspace=@common.Uri::file("/work/project"),
    ).after_quick_open_pick()
    is Screen::Chat,
  )
}
