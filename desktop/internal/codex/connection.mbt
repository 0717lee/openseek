// One initialized Codex app-server process and its JSON-RPC connection.

///|
/// App-server must answer initialize promptly. This bounds accidental launches
/// of an incompatible `codex` executable and a wedged child process.
const HandshakeTimeoutMs : Int = 30000

///|
/// The initialized JSON-RPC connection. Its tasks and child process belong to
/// the task group passed to `connect`; `shutdown` is an eager, idempotent close.
struct Connection {
  rpc : @jsonrpc.Client
  teardown : () -> Unit
}

///|
pub async fn Connection::request(
  self : Connection,
  method_~ : String,
  params~ : Json,
) -> Json {
  self.rpc.request(method_~, params~)
}

///|
pub async fn Connection::respond(
  self : Connection,
  request : @jsonrpc.PeerRequest,
  result : Json,
) -> Unit {
  self.rpc.respond(request, result)
}

///|
pub async fn Connection::respond_error(
  self : Connection,
  request : @jsonrpc.PeerRequest,
  code~ : Int,
  message~ : String,
) -> Unit {
  self.rpc.respond_error(request, code~, message~)
}

///|
pub fn Connection::is_closed(self : Connection) -> Bool {
  self.rpc.is_closed()
}

///|
pub fn Connection::shutdown(self : Connection) -> Unit {
  (self.teardown)()
}

///|
/// Spawn `codex app-server`, install the two inbound event receivers before
/// the handshake, then send the required initialize/initialized pair. Returns
/// `None` after fully tearing down any spawn, protocol, or timeout failure.
pub async fn[X] connect(
  group : @async.TaskGroup[X],
  command~ : String,
  notification_handler~ : (String, Json) -> Unit,
  request_handler~ : (@jsonrpc.PeerRequest) -> Bool,
  on_closed~ : () -> Unit,
  version~ : String,
  handshake_timeout_ms? : Int = HandshakeTimeoutMs,
) -> Connection? {
  let (child_stdin, stdin_writer) = @process.write_to_process() catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  let (stdout_reader, child_stdout) = @process.read_from_process() catch {
    error if @async.is_being_cancelled() => {
      stdin_writer.close()
      raise error
    }
    _ => {
      stdin_writer.close()
      return None
    }
  }
  let (stderr_reader, child_stderr) = @process.read_from_process() catch {
    error if @async.is_being_cancelled() => {
      stdout_reader.close()
      stdin_writer.close()
      raise error
    }
    _ => {
      stdout_reader.close()
      stdin_writer.close()
      return None
    }
  }
  let process = @process.spawn(
    group,
    command,
    ["app-server"],
    inherit_env=true,
    stdin=child_stdin,
    stdout=child_stdout,
    stderr=child_stderr,
    no_console_window=true,
    cancel_handler=@process.graceful_cancel(timeout=1000),
    no_wait=true,
  ) catch {
    error if @async.is_being_cancelled() => {
      stderr_reader.close()
      stdout_reader.close()
      stdin_writer.close()
      raise error
    }
    _ => {
      stderr_reader.close()
      stdout_reader.close()
      stdin_writer.close()
      return None
    }
  }
  let closed : Ref[Bool] = { val: false }
  let teardown_action : Ref[() -> Unit] = {
    val: () => {
      stderr_reader.close()
      stdout_reader.close()
      stdin_writer.close()
      process.cancel()
    },
  }
  let teardown = () => {
    if !closed.val {
      closed.val = true
      (teardown_action.val)()
      on_closed()
    }
  }
  let transport = StdioTransport(stdout_reader, stdin_writer, teardown~)
  let rpc = @jsonrpc.Client::new(transport)
  rpc.set_notification_handler(notification_handler)
  rpc.set_request_handler(request_handler)
  group.spawn_bg(() => rpc.run_message_pump(), no_wait=true, allow_failure=true)
  group.spawn_bg(() => rpc.run_writer(), no_wait=true, allow_failure=true)
  // Drain stderr independently for the process lifetime. App-server can emit
  // model-refresh and network diagnostics there; leaving the pipe unread can
  // fill it and stop protocol progress on stdout.
  group.spawn_bg(
    () => {
      for ;; {
        let chunk = stderr_reader.read_some(max_len=8192) catch {
          error if @async.is_being_cancelled() => raise error
          _ => None
        }
        guard chunk is Some(_) else { break }
      }
    },
    no_wait=true,
    allow_failure=true,
  )
  teardown_action.val = () => {
    // Closing the three pipes wakes the background tasks. They remain owned
    // by `group`, so the task group waits for their unwind before reconnecting.
    stderr_reader.close()
    stdout_reader.close()
    stdin_writer.close()
    process.cancel()
  }
  let initialized = @async.with_timeout_opt(handshake_timeout_ms, () => {
    rpc.request(method_="initialize", params={
      "clientInfo": {
        "name": "openseek_desktop",
        "title": "OpenSeek Desktop",
        "version": version,
      },
    })
  }) catch {
    error if @async.is_being_cancelled() => {
      teardown()
      raise error
    }
    _ => {
      teardown()
      return None
    }
  }
  guard initialized is Some(_) else {
    teardown()
    return None
  }
  rpc.notify(method_="initialized", params=Json::empty_object())
  Some({ rpc, teardown })
}
