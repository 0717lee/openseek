// The panel's bridge calls, routed by tab key. `terminal_open` folds its
// reply back into the update loop; the steady-state ops are fire-and-forget
// — input failures surface as `InputFailed` (an error toast),
// resize/close failures are dropped (their loss only degrades, and a dead
// session reports itself through `terminal_exit`). Flow-control acks retry
// until the host accepts their idempotent output sequence.

///|
const AckRetryDelayMs = 100

///|
fn open_session(
  dispatch : @cmd.Emit[Msg],
  key : Int,
  session : String,
  workspace : @pathx.Absolute?,
  cols : Int,
  rows : Int,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["session"] = session
      @interop.set_workspace(payload, workspace)
      payload["cols"] = cols
      payload["rows"] = rows
      let reply = @interop.bridge_request("terminal_open", payload.to_value()) catch {
        error => {
          scheduler.add(
            dispatch(
              OpenFailed(key~, message=@interop.bridge_error_text(error)),
            ),
          )
          return
        }
      }
      guard @interop.js_prop(reply, "id") is Some(value) else {
        scheduler.add(
          dispatch(OpenFailed(key~, message="malformed terminal_open reply")),
        )
        return
      }
      let id : Int = value.cast()
      scheduler.add(dispatch(Opened(key~, id~)))
    })
  })
}

///|
fn send_input(
  dispatch : @cmd.Emit[Msg],
  key : Int,
  id : Int,
  data : String,
  binary : Bool,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["id"] = id
      if binary {
        payload["data_base64"] = data
      } else {
        payload["data"] = data
      }
      let _ : @js.Value = @interop.bridge_request(
        "terminal_input",
        payload.to_value(),
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              InputFailed(key~, message=@interop.bridge_error_text(error)),
            ),
          )
          return
        }
      }
    })
  })
}

///|
fn send_resize(id : Int, cols : Int, rows : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["id"] = id
      payload["cols"] = cols
      payload["rows"] = rows
      let _ : @js.Value = @interop.bridge_request(
        "terminal_resize",
        payload.to_value(),
      ) catch {
        _ => return
      }
    })
  })
}

///|
/// One output acknowledgement. Retrying the same session/sequence pair is
/// safe because the host removes each outstanding sequence at most once.
priv struct TerminalAck {
  id : Int
  sequence : Int
}

///|
fn TerminalAck::send(self : TerminalAck) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["id"] = self.id
      payload["sequence"] = self.sequence
      let _ : @js.Value = @interop.bridge_request(
        "terminal_ack",
        payload.to_value(),
      ) catch {
        _ => {
          // A rejection can mean the host applied the ack but its response was
          // lost. Retry the same idempotent sequence after a short delay.
          _scheduler.add(@cmd.delay(self.send(), AckRetryDelayMs))
          return
        }
      }
    })
  })
}

///|
fn send_close(id : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["id"] = id
      let _ : @js.Value = @interop.bridge_request(
        "terminal_close",
        payload.to_value(),
      ) catch {
        _ => return
      }
    })
  })
}
