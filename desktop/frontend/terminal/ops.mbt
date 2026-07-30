// The panel's bridge calls. `terminal_open` folds its reply back into the
// update loop; the steady-state ops (input, resize, ack, close) are
// fire-and-forget — input failures surface as `OpenFailed` so the panel
// shows what broke, resize/ack/close failures are dropped (their loss only
// degrades, and a dead session reports itself through `terminal_exit`).

///|
fn open_session(
  dispatch : @cmd.Emit[Msg],
  ctx : Ctx,
  cols : Int,
  rows : Int,
) -> @cmd.Cmd {
  let session = ctx.session
  let workspace = ctx.workspace
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
              OpenFailed(session~, message=@interop.bridge_error_text(error)),
            ),
          )
          return
        }
      }
      guard @interop.js_prop(reply, "id") is Some(value) else {
        scheduler.add(
          dispatch(
            OpenFailed(session~, message="malformed terminal_open reply"),
          ),
        )
        return
      }
      let id : Int = value.cast()
      scheduler.add(dispatch(Opened(session~, id~)))
    })
  })
}

///|
fn send_input(
  dispatch : @cmd.Emit[Msg],
  session : String,
  id : Int,
  data : String,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["id"] = id
      payload["data"] = data
      let _ : @js.Value = @interop.bridge_request(
        "terminal_input",
        payload.to_value(),
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              OpenFailed(session~, message=@interop.bridge_error_text(error)),
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
fn send_ack(id : Int, bytes : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["id"] = id
      payload["bytes"] = bytes
      let _ : @js.Value = @interop.bridge_request(
        "terminal_ack",
        payload.to_value(),
      ) catch {
        _ => return
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
