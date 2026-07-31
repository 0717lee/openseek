// The integrated terminal's IPC surface: wire shapes and ops between the
// webview panel and the host's PTY sessions (internal/terminal). Output
// bytes cross the bridge base64-encoded — a PTY chunk may split a UTF-8
// sequence, so the wire stays byte-transparent and the webview feeds the
// decoded bytes straight into its emulator.

///|
priv struct TerminalOpenPayload {
  session : String
  // The workspace whose store holds the session, when the client knows it.
  workspace : String?
  cols : Int
  rows : Int
} derive(FromJson)

///|
priv struct TerminalOpenReply {
  id : Int
} derive(ToJson)

///|
/// User keystrokes as the emulator encoded them. Text arrives in `data` and
/// is UTF-8 encoded; xterm `onBinary` input arrives byte-transparent in
/// `data_base64`. Exactly one field must be present.
priv struct TerminalInputPayload {
  id : Int
  data : String?
  data_base64 : String?
} derive(FromJson)

///|
fn TerminalInputPayload::bytes(
  self : TerminalInputPayload,
) -> Bytes raise HostError {
  match (self.data, self.data_base64) {
    (Some(data), None) => @utf8.encode(data)
    (None, Some(data)) =>
      @base64.decode(data) catch {
        _ => raise HostError("terminal input contains invalid base64")
      }
    _ => raise HostError("terminal input must contain exactly one data field")
  }
}

///|
priv struct TerminalResizePayload {
  id : Int
  cols : Int
  rows : Int
} derive(FromJson)

///|
/// Flow control: the webview acknowledges an output chunk after the emulator
/// finishes rendering it. The sequence makes a retried request idempotent.
priv struct TerminalAckPayload {
  id : Int
  sequence : Int
} derive(FromJson)

///|
priv struct TerminalClosePayload {
  id : Int
} derive(FromJson)

///|
/// `terminal_output` event: `data` is base64 of raw PTY bytes. `sequence`
/// identifies the chunk so the webview can safely retry its acknowledgement.
priv struct TerminalOutputPayload {
  id : Int
  sequence : Int
  data : String
} derive(ToJson)

///|
/// `terminal_exit` event.
priv struct TerminalExitPayload {
  id : Int
  code : Int
} derive(ToJson)

///|
/// Open a login-shell session rooted in the conversation's workspace.
async fn terminal_open_op(
  terminals : @terminal.TerminalState,
  payload : TerminalOpenPayload,
) -> TerminalOpenReply {
  guard @engine.resolve_in_workspace(
      payload.session,
      "",
      workspace?=payload.workspace,
    )
    is Some(root) else {
    raise HostError("terminal requires a conversation workspace")
  }
  // A scratch conversation's workspace directory is created lazily by its
  // first run, so a terminal opened before that would start in a directory
  // that does not exist yet. Create it here the same way the engine does —
  // for a registered workspace this is a no-op.
  @fsx.ensure_dir(root) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise HostError("could not open the workspace directory: \{error}")
  }
  let id = @terminal.open_terminal(
    terminals,
    cwd=root.to_string(),
    cols=payload.cols,
    rows=payload.rows,
  ) catch {
    @terminal.TerminalError(message) => raise HostError(message)
    error => raise error
  }
  { id, }
}

///|
async fn terminal_input_op(
  terminals : @terminal.TerminalState,
  payload : TerminalInputPayload,
) -> Unit {
  @terminal.write_terminal(terminals, id=payload.id, payload.bytes()) catch {
    @terminal.TerminalError(message) => raise HostError(message)
    error => raise error
  }
}

///|
fn terminal_resize_op(
  terminals : @terminal.TerminalState,
  payload : TerminalResizePayload,
) -> Unit raise {
  @terminal.resize_terminal(
    terminals,
    id=payload.id,
    cols=payload.cols,
    rows=payload.rows,
  ) catch {
    @terminal.TerminalError(message) => raise HostError(message)
    error => raise error
  }
}

///|
fn terminal_ack_op(
  terminals : @terminal.TerminalState,
  payload : TerminalAckPayload,
) -> Unit {
  @terminal.ack_terminal(terminals, id=payload.id, sequence=payload.sequence)
}

///|
fn terminal_close_op(
  terminals : @terminal.TerminalState,
  payload : TerminalClosePayload,
) -> Unit {
  @terminal.close_terminal(terminals, id=payload.id)
}

///|
/// Forward one session push to the webview as its wire event.
async fn emit_terminal_push(
  context : @app.AppCommandExtensionContext,
  push : @terminal.TerminalPush,
) -> Unit {
  match push {
    Output(id~, sequence~, data~) => {
      let payload : TerminalOutputPayload = {
        id,
        sequence,
        data: @base64.encode(data),
      }
      context.emit("terminal_output", payload)
    }
    Exited(id~, code~) => {
      let payload : TerminalExitPayload = { id, code }
      context.emit("terminal_exit", payload)
    }
  }
}
