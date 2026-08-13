// One dsh Web process plus its existing HTTP/WebSocket API carriers. Desktop
// does not define another dsh business protocol: requests and event envelopes
// retain the exact ApiProxy wire shapes served under /api.

///|
const HandshakeTimeoutMs : Int = 60_000

///|
const RequestTimeoutMs : Int = 120_000

///|
const MaxResponseBytes : Int = 32 * 1024 * 1024

///|
const MaxEventBytes : Int = 8 * 1024 * 1024

///|
priv struct ReadyLine(String)

///|
/// Decode only dsh Web's documented readiness line. Extra display text after
/// the loopback URL, such as the optional LAN address, is not part of the API
/// origin retained by Desktop.
fn ReadyLine::url(self : ReadyLine) -> String? {
  guard self.0.trim().strip_prefix("dsh web: ") is Some(rest) else {
    return None
  }
  let url = rest.split(" ").head().unwrap_or("").trim().to_owned()
  if url.has_prefix("http://127.0.0.1:") || url.has_prefix("http://localhost:") {
    Some(url)
  } else {
    None
  }
}

///|
/// One initialized dsh Web process. Its process and stream tasks belong to
/// the task group passed to `connect`; `shutdown` is an eager idempotent close.
priv struct Connection {
  base_url : String
  teardown : () -> Unit
}

///|
fn Connection::shutdown(self : Connection) -> Unit {
  (self.teardown)()
}

///|
/// Send one complete ApiProxy client-request envelope over the existing HTTP
/// carrier. The response remains a full server-response so the frontend can
/// distinguish business failures from transport failures without Desktop
/// duplicating dsh's error catalog.
async fn Connection::request(
  self : Connection,
  method_~ : String,
  rpc_id~ : String,
  payload~ : Json,
) -> Json {
  let response = self.post("/api/" + method_, {
    "type": "client-request",
    "rpcId": rpc_id,
    "method": method_,
    "payload": payload,
  })
  guard response is Object(fields) &&
    fields.get("type") is Some(String("server-response")) &&
    fields.get("rpcId") is Some(String(response_id)) &&
    response_id == rpc_id &&
    fields.get("result") is Some(_) else {
    raise DshError::RequestFailed(
      method_, "dsh returned a malformed or mismatched server-response",
    )
  }
  response
}

///|
/// Carry one client-response to dsh's pending approval/question registry.
async fn Connection::respond(self : Connection, message : Json) -> Json {
  self.post("/api/respond", message)
}

///|
async fn Connection::post(
  self : Connection,
  path : String,
  body : Json,
) -> Json {
  let body_text = body.stringify()
  if @utf8.encode(body_text).length() > MaxEventBytes {
    raise DshError::RequestFailed(path, "request exceeds 8 MiB")
  }
  guard @async.with_timeout_opt(RequestTimeoutMs, () => {
      let client = @http.post_stream(self.base_url + path, headers={
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Accept-Encoding": "identity",
      })
      defer client.close()
      client.write(body_text)
      let response = client.end_request()
      guard response.code == 200 else {
        raise DshError::RequestFailed(path, "HTTP \{response.code}")
      }
      let bytes = FixedArray::make(MaxResponseBytes + 1, b'\x00')
      let mut received = 0
      for ;; {
        let count = client.read(
          bytes,
          offset=received,
          max_len=bytes.length() - received,
        )
        if count == 0 {
          break
        }
        received += count
        if received > MaxResponseBytes {
          raise DshError::RequestFailed(path, "response exceeds 32 MiB")
        }
      }
      let text = @utf8.decode(bytes.unsafe_reinterpret_as_bytes()[:received])
      @json.parse(text) catch {
        _ => raise DshError::RequestFailed(path, "response is not JSON")
      }
    })
    is Some(result) else {
    raise DshError::RequestFailed(path, "request timed out after 120 seconds")
  }
  result
}

///|
/// Pump one downlink-only WebSocket. A malformed or oversized event ends this
/// connection so the actor can reopen both streams and dsh can replay its
/// authoritative baselines and still-pending interactions together.
async fn Connection::pump(
  self : Connection,
  stream : String,
  receive : (String, Json) -> Bool,
) -> Unit {
  let origin = match self.base_url.strip_prefix("http://") {
    Some(rest) => "ws://" + rest.to_owned()
    None =>
      raise DshError::RequestFailed(stream, "dsh URL is not loopback HTTP")
  }
  let conn = @websocket.Conn::connect(origin + "/api/events." + stream)
  defer conn.close()
  for ;; {
    let message = conn.recv()
    guard message.kind is Text else {
      raise DshError::RequestFailed(stream, "dsh sent a binary WebSocket frame")
    }
    let bytes = FixedArray::make(MaxEventBytes + 1, b'\x00')
    let mut received = 0
    for ;; {
      let count = message.read(
        bytes,
        offset=received,
        max_len=bytes.length() - received,
      )
      if count == 0 {
        break
      }
      received += count
      if received > MaxEventBytes {
        raise DshError::RequestFailed(stream, "event exceeds 8 MiB")
      }
    }
    let text = @utf8.decode(bytes.unsafe_reinterpret_as_bytes()[:received])
    let value = @json.parse(text) catch {
      _ => raise DshError::RequestFailed(stream, "event is not JSON")
    }
    if !receive(stream, value) {
      raise DshError::RequestFailed(stream, "Desktop event queue is full")
    }
  }
}

///|
/// Spawn `dsh web` on an OS-assigned loopback port and wait for its readiness
/// line. The two WebSocket pumps start only after this function returns, so a
/// ready status always names an origin whose complete Loader tree settled.
async fn[X] Connection::connect(group : @async.TaskGroup[X]) -> Connection? {
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
  // dsh owns its installation and Node runtime. Desktop only invokes the
  // executable made available through the login-shell PATH.
  let process = @process.spawn(
    group,
    "dsh",
    ["web", "--host", "127.0.0.1", "--port", "0"],
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
  let teardown = () => {
    if !closed.val {
      closed.val = true
      stderr_reader.close()
      stdout_reader.close()
      stdin_writer.close()
      process.cancel()
    }
  }
  group.spawn_bg(
    () => {
      for ;; {
        let line = stderr_reader.read_until("\n") catch {
          error if @async.is_being_cancelled() => raise error
          _ => None
        }
        guard line is Some(line) else { break }
        @xlog.debug(category="dsh") <? { "event": "dsh_stderr", "line": line }
      }
    },
    no_wait=true,
    allow_failure=true,
  )
  let ready = @async.with_timeout_opt(HandshakeTimeoutMs, () => {
    for ;; {
      guard stdout_reader.read_until("\n") is Some(line) else { return None }
      if ReadyLine(line).url() is Some(url) {
        return Some(url)
      }
      @xlog.debug(category="dsh") <? { "event": "dsh_stdout", "line": line }
    }
  }) catch {
    error if @async.is_being_cancelled() => {
      teardown()
      raise error
    }
    error => {
      @xlog.warn(category="dsh") <?
        { "event": "dsh_readiness_failed", "error": "\{error}" }
      teardown()
      return None
    }
  }
  guard ready is Some(Some(base_url)) else {
    teardown()
    return None
  }
  group.spawn_bg(
    () => {
      for ;; {
        let line = stdout_reader.read_until("\n") catch {
          error if @async.is_being_cancelled() => raise error
          _ => None
        }
        guard line is Some(line) else { break }
        @xlog.debug(category="dsh") <? { "event": "dsh_stdout", "line": line }
      }
    },
    no_wait=true,
    allow_failure=true,
  )
  Some({ base_url, teardown })
}

///|
test "dsh readiness accepts only a loopback API origin" {
  assert_eq(
    ReadyLine("dsh web: http://127.0.0.1:4123").url(),
    Some("http://127.0.0.1:4123"),
  )
  assert_eq(
    ReadyLine("dsh web: http://localhost:4123 (LAN: http://10.0.0.2:4123)").url(),
    Some("http://localhost:4123"),
  )
  assert_eq(ReadyLine("dsh web: http://10.0.0.2:4123").url(), None)
  assert_eq(ReadyLine("other output").url(), None)
}
