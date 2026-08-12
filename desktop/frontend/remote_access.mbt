// The host's relay sign-in, over the wire: `auth.status` seeds the mirror
// at bridge time, `auth.connect`/`auth.disconnect` drive it from the
// Settings page, and the `auth.changed` broadcast keeps it fresh (projected
// in bridge.mbt through the same `RemoteAccess::from_status`). Desktop-window
// ops by convention — a browser signs in with the relay directly — so every
// call here is pinned to the `Local` channel: the section describes this
// host's own relay registration, never a focused remote device's.

///|
/// Project the shared auth status used by both replies and broadcasts.
fn RemoteAccess::from_status(
  payload : @protocol.AuthStatusPayload,
) -> RemoteAccess {
  let user_login = payload.user.map(user => user.login)
  let (device_name, device_url) = match payload.device {
    Some(device) => (Some(device.name), Some(device.url))
    None => (None, None)
  }
  {
    server_url: payload.server_url,
    connected: payload.connected,
    managed_by_env: payload.managed_by_env.unwrap_or(false),
    user_login,
    device_name,
    device_url,
  }
}

///|
/// Seed (or refresh) the mirror. A failed or malformed reply leaves the
/// current mirror in place — `auth.changed` corrects it on the next move.
fn fetch_remote_status(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let response = @interop.bridge_request(
        Local,
        @commands.auth_status,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        _ => return
      }
      guard response is AuthStatus(status) else { return }
      scheduler.add(
        dispatch(RemoteStatusLoaded(RemoteAccess::from_status(status))),
      )
    })
  })
}

///|
/// Run the loopback sign-in. The reply arrives only after the user's
/// browser round-trip, minutes later at the worst — the section shows an
/// in-progress state the whole while.
fn connect_remote(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let response = @interop.bridge_request(
        Local,
        @commands.auth_connect,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        error => {
          scheduler.add(
            dispatch(RemoteConnectFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
      let status = match response {
        AuthStatus(status) => status
        AuthError(message) => {
          scheduler.add(dispatch(RemoteConnectFailed(message)))
          return
        }
      }
      scheduler.add(
        dispatch(RemoteConnectFinished(RemoteAccess::from_status(status))),
      )
    })
  })
}

///|
/// Abort a waiting sign-in. The connect's own failure reply settles the
/// section, so this only surfaces its *own* failure (a dead bridge).
fn cancel_remote(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let response = @interop.bridge_request(
        Local,
        @commands.auth_cancel,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        error => {
          scheduler.add(
            dispatch(RemoteDisconnectFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
      if response is AuthError(message) {
        scheduler.add(dispatch(RemoteDisconnectFailed(message)))
      }
    })
  })
}

///|
/// Sign out. Success comes back as the post-sign-out status.
fn disconnect_remote(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let response = @interop.bridge_request(
        Local,
        @commands.auth_disconnect,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        error => {
          scheduler.add(
            dispatch(RemoteDisconnectFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
      let status = match response {
        AuthStatus(status) => status
        AuthError(message) => {
          scheduler.add(dispatch(RemoteDisconnectFailed(message)))
          return
        }
      }
      scheduler.add(
        dispatch(RemoteStatusLoaded(RemoteAccess::from_status(status))),
      )
    })
  })
}
