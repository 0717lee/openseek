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
  for name, _ in fields {
    if name != "value" {
      raise JsonDecodeError((path.add_key(name), "unknown field"))
    }
  }
  { value, }
}

///|
pub impl ToJson for DshValueReply with fn to_json(self) {
  { "value": self.value }
}
