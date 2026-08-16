// Typed Desktop envelopes for the DeepSeek Harness carrier. The nested dsh
// request and reply documents remain JSON because dsh versions that schema;
// the enclosing Desktop contract is strict and evolves with its frontend.

///|
/// Object-shaped input for dsh commands that take no arguments. Unknown fields
/// are rejected so a mistyped Desktop payload cannot be silently ignored.
pub(all) enum DshEmptyPayload {
  DshNoPayload
} derive(Debug, Eq)

///|
/// One allowlisted dsh ApiProxy call. `payload` is required but may contain any
/// JSON value, including `null`, because its shape belongs to the named method.
pub(all) struct DshRequestPayload {
  method_ : String
  payload : Json
} derive(Debug, Eq)

///|
/// One complete dsh client-response document. The Desktop endpoint validates
/// its versioned inner shape before forwarding it to the actor.
pub(all) struct DshRespondPayload {
  message : Json
} derive(Debug, Eq)

///|
/// Preserve one complete dsh reply inside a stable Desktop-owned envelope.
/// `value` is required and deliberately permits every JSON value, including
/// `null`; malformed JSON is rejected by the transport before this codec runs.
pub(all) struct DshValueReply {
  value : Json
  // Present for actor-dispatched requests. session.list uses the revision
  // captured when its HTTP call actually starts to order the returned
  // baseline against host/session-status notifications.
  session_revision : Int?
} derive(Debug, Eq)

///|
/// Desktop-owned connection-state notification. `message` is omitted outside
/// the unavailable state; explicit `null` decodes to the same absence.
pub(all) struct DshStatusNotification {
  status : String
  message : String?
  revision : Int
} derive(Debug, Eq)

///|
/// Desktop-owned wrapper for one dsh WebSocket document. The nested message is
/// versioned by dsh and may be any JSON value, including `null`.
pub(all) struct DshEventNotification {
  stream : String
  message : Json
  generation : Int
  session_revision : Int
} derive(Debug, Eq)

///|
pub impl FromJson for DshEmptyPayload with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh empty payload object"))
  }
  for name, _ in fields {
    raise JsonDecodeError((path.add_key(name), "unknown field"))
  }
  DshNoPayload
}

///|
pub impl ToJson for DshEmptyPayload with fn to_json(_self) {
  Json::empty_object()
}

///|
pub impl FromJson for DshRequestPayload with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh request payload object"))
  }
  let method_ = match fields.get("method") {
    Some(String(method_)) => method_
    Some(_) =>
      raise JsonDecodeError((path.add_key("method"), "expected string"))
    None =>
      raise JsonDecodeError((path.add_key("method"), "missing required field"))
  }
  let payload = match fields.get("payload") {
    Some(payload) => payload
    None =>
      raise JsonDecodeError((path.add_key("payload"), "missing required field"))
  }
  for name, _ in fields {
    if name != "method" && name != "payload" {
      raise JsonDecodeError((path.add_key(name), "unknown field"))
    }
  }
  { method_, payload }
}

///|
pub impl ToJson for DshRequestPayload with fn to_json(self) {
  { "method": Json::string(self.method_), "payload": self.payload }
}

///|
pub impl FromJson for DshRespondPayload with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh response payload object"))
  }
  let message = match fields.get("message") {
    Some(message) => message
    None =>
      raise JsonDecodeError((path.add_key("message"), "missing required field"))
  }
  for name, _ in fields {
    if name != "message" {
      raise JsonDecodeError((path.add_key(name), "unknown field"))
    }
  }
  { message, }
}

///|
pub impl ToJson for DshRespondPayload with fn to_json(self) {
  { "message": self.message }
}

///|
pub impl FromJson for DshValueReply with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh reply envelope object"))
  }
  let value = match fields.get("value") {
    Some(value) => value
    None =>
      raise JsonDecodeError((path.add_key("value"), "missing required field"))
  }
  let session_revision : Int? = match fields.get("sessionRevision") {
    Some(value) =>
      Some(
        @json.from_json(value, path=path.add_key("sessionRevision")) catch {
          _ =>
            raise JsonDecodeError(
              (path.add_key("sessionRevision"), "expected integer"),
            )
        },
      )
    None => None
  }
  for name, _ in fields {
    if name != "value" && name != "sessionRevision" {
      raise JsonDecodeError((path.add_key(name), "unknown field"))
    }
  }
  { value, session_revision }
}

///|
pub impl ToJson for DshValueReply with fn to_json(self) {
  let fields : Map[String, Json] = Map([("value", self.value)])
  if self.session_revision is Some(revision) {
    fields["sessionRevision"] = revision.to_json()
  }
  Json::object(fields)
}

///|
pub impl FromJson for DshStatusNotification with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh status notification object"))
  }
  let status = match fields.get("status") {
    Some(String(status)) => status
    Some(_) =>
      raise JsonDecodeError((path.add_key("status"), "expected string"))
    None =>
      raise JsonDecodeError((path.add_key("status"), "missing required field"))
  }
  let message = match fields.get("message") {
    Some(String(message)) => Some(message)
    Some(Null) | None => None
    Some(_) =>
      raise JsonDecodeError(
        (path.add_key("message"), "expected string or null"),
      )
  }
  let revision : Int = match fields.get("revision") {
    Some(value) =>
      @json.from_json(value, path=path.add_key("revision")) catch {
        _ =>
          raise JsonDecodeError((path.add_key("revision"), "expected integer"))
      }
    None =>
      raise JsonDecodeError(
        (path.add_key("revision"), "missing required field"),
      )
  }
  for name, _ in fields {
    if name != "status" && name != "message" && name != "revision" {
      raise JsonDecodeError((path.add_key(name), "unknown field"))
    }
  }
  { status, message, revision }
}

///|
pub impl ToJson for DshStatusNotification with fn to_json(self) {
  let fields : Map[String, Json] = Map([
    ("status", Json::string(self.status)),
    ("revision", self.revision.to_json()),
  ])
  if self.message is Some(message) {
    fields["message"] = Json::string(message)
  }
  Json::object(fields)
}

///|
pub impl FromJson for DshEventNotification with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh event notification object"))
  }
  let stream = match fields.get("stream") {
    Some(String(stream)) => stream
    Some(_) =>
      raise JsonDecodeError((path.add_key("stream"), "expected string"))
    None =>
      raise JsonDecodeError((path.add_key("stream"), "missing required field"))
  }
  let message = match fields.get("message") {
    Some(message) => message
    None =>
      raise JsonDecodeError((path.add_key("message"), "missing required field"))
  }
  let generation : Int = match fields.get("generation") {
    Some(value) =>
      @json.from_json(value, path=path.add_key("generation")) catch {
        _ =>
          raise JsonDecodeError(
            (path.add_key("generation"), "expected integer"),
          )
      }
    None =>
      raise JsonDecodeError(
        (path.add_key("generation"), "missing required field"),
      )
  }
  let session_revision : Int = match fields.get("sessionRevision") {
    Some(value) =>
      @json.from_json(value, path=path.add_key("sessionRevision")) catch {
        _ =>
          raise JsonDecodeError(
            (path.add_key("sessionRevision"), "expected integer"),
          )
      }
    None =>
      raise JsonDecodeError(
        (path.add_key("sessionRevision"), "missing required field"),
      )
  }
  for name, _ in fields {
    if name != "stream" &&
      name != "message" &&
      name != "generation" &&
      name != "sessionRevision" {
      raise JsonDecodeError((path.add_key(name), "unknown field"))
    }
  }
  { stream, message, generation, session_revision }
}

///|
pub impl ToJson for DshEventNotification with fn to_json(self) {
  {
    "stream": Json::string(self.stream),
    "message": self.message,
    "generation": self.generation,
    "sessionRevision": self.session_revision,
  }
}
