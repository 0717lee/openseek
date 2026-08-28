///|
/// The native save-dialog operation for one already-rendered export.
priv struct SessionExportDialog {
  session : String
}

///|
fn SessionExportDialog::SessionExportDialog(
  session : String,
) -> SessionExportDialog {
  { session, }
}

///|
/// Wait for Proton's asynchronous native save dialog without blocking the app
/// event loop. Closing the dialog returns `None` and creates no file.
async fn SessionExportDialog::destination(
  self : SessionExportDialog,
  context : @proton.CommandContext,
) -> String? {
  let window = @native.WindowRef::unsafe_from_handle(context.window())
  let dialog = window.begin_save_file_dialog(
    Some("Export conversation"),
    Some("\{self.session}.html"),
  ) catch {
    error =>
      raise @host.HostError(
        "could not open the save dialog: \{error.message()}",
      )
  }
  for ;; {
    let revision = context.wake_revision()
    let result = window.poll_dialog_result(dialog) catch {
      error =>
        raise @host.HostError(
          "could not read the save dialog: \{error.message()}",
        )
    }
    match result {
      Ready(path) => {
        if path.is_empty() {
          return None
        }
        // Preserve the exact destination confirmed by the native dialog. The
        // suggested name already carries `.html`; changing the returned path
        // here would bypass the dialog's overwrite confirmation for that path.
        return Some(path)
      }
      Pending => context.wait_for_wake(revision)
    }
  }
}

///|
/// Render at click time, then ask for a destination and write only after the
/// user confirms it. Rendering first keeps record locks out of the time the
/// native dialog is open. Opening is best-effort after the durable write: its
/// failure is returned separately so the UI never reports a saved export as
/// failed.
async fn export_session(
  context : @proton.CommandContext,
  state : @api.ApiState,
  payload : @protocol.SessionExportPayload,
) -> @protocol.SessionExportReply {
  let assets = state.host_state().viz_assets()
  let (shell, bundle) = assets.read()
  let html = @engine.export_session_html(
    state.manager(),
    payload,
    shell,
    bundle,
  )
  let dialog = SessionExportDialog(payload.session)
  guard dialog.destination(context) is Some(path) else {
    return { path: None, opened: false, }
  }
  // The native dialog has already confirmed replacement for this exact path.
  // `CreateNew` would incorrectly reject an overwrite the user approved.
  @fs.write_file(path, html, create_mode=CreateOrTruncate) catch {
    error =>
      raise @host.HostError("could not save the conversation export: \{error}")
  }
  let open_code = @platform.open_path(path) catch {
    error if @async.is_being_cancelled() => raise error
    _ => -1
  }
  { path: Some(path), opened: open_code == 0, }
}
