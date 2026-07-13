// The self-update flow, driven from this side: the app asks `check_update`
// once at startup (and whenever the user asks in Settings), shows an accent
// Update button while a release is installable, and on click walks
// `download_update` → `apply_update` → window close, confirming first when
// a conversation would be interrupted.

///|
/// Which release stream `check_update` asks. A Settings choice; Staging
/// exists to exercise a release before it goes live.
priv enum UpdateChannel {
  Production
  Staging
}

///|
fn UpdateChannel::parse(value : String) -> UpdateChannel {
  match value {
    "staging" => Staging
    _ => Production
  }
}

///|
fn UpdateChannel::wire(self : UpdateChannel) -> String {
  match self {
    Production => "production"
    Staging => "staging"
  }
}

///|
/// Where the self-update flow stands. Who asked (the user from Settings or
/// the app at startup) travels with the request instead — `explicit` on
/// `UpdateCheckFinished` — since it is a property of the reply's routing,
/// not of the state.
priv enum UpdateUx {
  UpdateUnknown
  CheckingForUpdate
  UpToDate
  // A newer release; `installable` gates the accent Update button — a dev
  // binary or a platform without a package only gets the announcement.
  UpdateAvailable(version~ : String, installable~ : Bool)
  // The modal asking to interrupt running conversations is up.
  ConfirmingRestart(version~ : String)
  DownloadingUpdate(version~ : String)
  // The bundle is swapped; the window is about to close.
  RestartingForUpdate(version~ : String)
  // What the Settings row shows when a check could not answer.
  UpdateCheckFailed(message~ : String)
}

///|
/// A decoded `check_update` reply. Kinds mirror the wire contract; see the
/// host's `CheckUpdateReply` for what each means and how loud it deserves
/// to be.
priv enum UpdateCheck {
  CheckUpToDate
  CheckFound(version~ : String, installable~ : Bool)
  CheckUnreachable(reason~ : String)
  CheckMalformed(reason~ : String)
  CheckBroken(version~ : String, reason~ : String)
}

///|
fn update_check_from_reply(reply : @protocol.CheckUpdateReply) -> UpdateCheck {
  match reply {
    @protocol.UpToDate => CheckUpToDate
    @protocol.Available(version~, installable~) =>
      CheckFound(version~, installable~)
    @protocol.Unreachable(reason~) => CheckUnreachable(reason~)
    @protocol.Malformed(reason~) => CheckMalformed(reason~)
    @protocol.Broken(version~, reason~) => CheckBroken(version~, reason~)
  }
}

///|
/// Ask the host to check the channel's manifest. Every outcome lands in
/// `UpdateCheckFinished`: op failures (bridge missing, host error) fold
/// into `CheckUnreachable`, so the handler has one shape to route.
fn check_for_updates(
  dispatch : @cmd.Emit[Msg],
  channel : UpdateChannel,
  explicit~ : Bool,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.UpdateChannelPayload = {
        channel: Some(channel.wire()),
      }
      let result = try {
        let raw_reply = @interop.bridge_request("check_update", payload)
        let reply : @protocol.CheckUpdateReply? = @interop.bridge_reply(
          raw_reply,
        )
        match reply {
          Some(reply) => update_check_from_reply(reply)
          None => CheckUnreachable(reason="the host answered unintelligibly")
        }
      } catch {
        error => CheckUnreachable(reason=@interop.bridge_error_text(error))
      }
      scheduler.add(dispatch(UpdateCheckFinished(result~, explicit~)))
    })
  })
}

///|
/// Ask the host to download and verify the channel's package. Success means
/// a staged bundle is waiting for `apply_update`.
fn download_update(
  dispatch : @cmd.Emit[Msg],
  channel : UpdateChannel,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.UpdateChannelPayload = {
        channel: Some(channel.wire()),
      }
      let _ : @js.Value = @interop.bridge_request("download_update", payload) catch {
        error => {
          scheduler.add(
            dispatch(UpdateFailed(message=@interop.bridge_error_text(error))),
          )
          return
        }
      }
      scheduler.add(dispatch(UpdateDownloaded))
    })
  })
}

///|
/// Whether restarting now would cut a conversation off mid-run.
fn Model::any_conversation_busy(self : Model) -> Bool {
  self.conversations
  .iter()
  .any(conv => conv.is_running() || !(conv.compaction is NotCompacting))
}
