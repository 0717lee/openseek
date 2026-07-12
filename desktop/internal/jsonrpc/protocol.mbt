// The JSON-RPC 2.0 message layer: the error a request can fail with, the
// envelope builders, and the classification the client routes inbound messages
// on. All pure (no transport), so it is unit-testable without a transport.

///|
/// Why a request did not yield a result: the peer answered with a JSON-RPC error
/// object, or the transport ended before any reply arrived.
pub(all) suberror ResponseError {
  Failed(code~ : Int, message~ : String)
  Closed
}

///|
impl Show for ResponseError with fn output(self, logger) {
  match self {
    Failed(code~, message~) =>
      logger.write_string("JSON-RPC error \{code}: \{message}")
    Closed => logger.write_string("transport closed before a reply")
  }
}

///|
/// Build a request envelope with a numeric id. Numeric ids let the client
/// correlate replies by `Int` rather than carrying arbitrary id shapes.
fn build_request(id : Int, method_ : String, params : Json) -> Json {
  {
    "jsonrpc": "2.0",
    "id": Json::number(id.to_double()),
    "method": method_,
    "params": params,
  }
}

///|
/// Build a notification envelope — a request with no id, which the peer never
/// answers.
fn build_notification(method_ : String, params : Json) -> Json {
  { "jsonrpc": "2.0", "method": method_, "params": params }
}

///|
/// The JSON-RPC reserved code for an unimplemented method.
const MethodNotFound : Int = -32601

///|
/// Build a "method not found" error reply echoing a peer request's id. A generic
/// client serves no methods, so any request the peer sends us gets this — a
/// proper JSON-RPC error rather than a misleading empty success, while still
/// answering so the peer does not block on its request.
fn build_error_reply(id : Json) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": {
      "code": Json::number(MethodNotFound.to_double()),
      "message": "Method not found",
    },
  }
}

///|
/// What an inbound message is, so the client can route it: a reply to one of our
/// requests (carrying the outcome to deliver), a request *from* the peer we must
/// answer, or a notification we ignore.
priv enum Incoming {
  Reply(Int, Result[Json, ResponseError])
  // A peer-initiated request; carries the raw id to echo back in the reply.
  PeerRequest(Json)
  // A peer-initiated notification: its method and params, delivered to the
  // client's notification handler (e.g. LSP `textDocument/publishDiagnostics`).
  Notification(String, Json)
  // Neither — malformed, or a reply with a non-numeric id we never issue.
  Unknown
}

///|
/// Classify an inbound message. A `method` field marks a request (with id) or a
/// notification (without); otherwise an `id` marks a reply.
fn classify_incoming(message : Json) -> Incoming {
  if message is { "method": String(method_), .. } {
    match message {
      { "id": id, .. } => PeerRequest(id)
      { "params": params, .. } => Notification(method_, params)
      _ => Notification(method_, Json::null())
    }
  } else {
    match message {
      { "id": Number(id, ..), .. } => Reply(id.to_int(), parse_outcome(message))
      _ => Unknown
    }
  }
}

///|
/// Read the outcome of a reply: its `result` on success, an error otherwise. A
/// reply with neither is treated as a successful empty result.
fn parse_outcome(message : Json) -> Result[Json, ResponseError] {
  match message {
    { "result": value, .. } => Ok(value)
    { "error": error, .. } => Err(parse_error(error))
    _ => Ok(Json::null())
  }
}

///|
/// Pull `code`/`message` out of a JSON-RPC error object, defaulting each when
/// the peer omits it.
fn parse_error(error : Json) -> ResponseError {
  let code = match error {
    { "code": Number(code, ..), .. } => code.to_int()
    _ => 0
  }
  let message = match error {
    { "message": String(message), .. } => message
    _ => ""
  }
  Failed(code~, message~)
}

///|
test "build_request carries jsonrpc, numeric id, method and params" {
  let params : Json = { "textDocument": { "uri": "openseek:///a.mbt" } }
  let request = build_request(7, "textDocument/hover", params)
  assert_true(
    request
    is {
      "jsonrpc": String("2.0"),
      "id": Number(7, ..),
      "method": String("textDocument/hover"),
      "params": {
        "textDocument": { "uri": String("openseek:///a.mbt"), .. },
        ..
      },
      ..
    },
  )
}

///|
test "build_notification omits the id" {
  let note = build_notification("initialized", Json::empty_object())
  assert_true(note is { "method": String("initialized"), .. })
  assert_true(!(note is { "id": _, .. }))
}

///|
test "build_error_reply answers a peer request with a method-not-found error" {
  let reply = build_error_reply(Json::number(5))
  assert_true(
    reply
    is {
      "id": Number(5, ..),
      "error": {
        "code": Number(-32601, ..),
        "message": String("Method not found"),
        ..
      },
      ..
    },
  )
  // An error reply, not a misleading empty success.
  assert_true(!(reply is { "result": _, .. }))
}

///|
test "classify_incoming routes a successful reply by id" {
  let message : Json = {
    "jsonrpc": "2.0",
    "id": 3,
    "result": { "contents": "Int" },
  }
  match classify_incoming(message) {
    Reply(id, Ok(value)) => {
      assert_eq(id, 3)
      assert_true(value is { "contents": String("Int"), .. })
    }
    _ => fail("expected a successful Reply")
  }
}

///|
test "classify_incoming parses an error reply into a typed failure" {
  let message : Json = {
    "jsonrpc": "2.0",
    "id": 4,
    "error": { "code": -32601, "message": "method not found" },
  }
  match classify_incoming(message) {
    Reply(id, Err(Failed(code~, message~))) => {
      assert_eq(id, 4)
      assert_eq(code, -32601)
      assert_eq(message, "method not found")
    }
    _ => fail("expected a failed Reply")
  }
}

///|
test "classify_incoming distinguishes peer requests from notifications" {
  let peer_request : Json = {
    "jsonrpc": "2.0",
    "id": 9,
    "method": "window/workDoneProgress/create",
  }
  match classify_incoming(peer_request) {
    PeerRequest(id) => assert_true(id is Number(9, ..))
    _ => fail("expected a PeerRequest")
  }
  let notification : Json = {
    "jsonrpc": "2.0",
    "method": "textDocument/publishDiagnostics",
  }
  match classify_incoming(notification) {
    Notification(_, _) => ()
    _ => fail("expected a Notification")
  }
}

///|
test "classify_incoming treats an id-less, method-less message as unknown" {
  match classify_incoming({ "jsonrpc": "2.0" }) {
    Unknown => ()
    _ => fail("expected Unknown")
  }
}
