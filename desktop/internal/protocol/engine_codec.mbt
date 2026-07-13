// Manual JSON codecs for the engine-facing half of the desktop bridge. The
// native host decodes these payloads and encodes these replies; the JS
// frontend does the reverse. Optional fields are omitted instead of using the
// core Option JSON representation, preserving the bridge's object contract.

///|
pub impl ToJson for EmptyPayload with fn to_json(_self) {
  Json::empty_object()
}

///|
pub impl FromJson for EmptyPayload with fn from_json(_json, _path) {
  // These operations historically ignored their argument altogether. The
  // typed frontend emits {}, while accepting any JSON keeps older callers
  // wire-compatible.
  let empty = EmptyPayload::{  }
  empty
}

///|
pub impl ToJson for WslPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([])
  @jsonx.put_optional(fields, "distro", self.distro)
  @jsonx.put_optional(fields, "engine", self.engine)
  Json::object(fields)
}

///|
pub impl FromJson for WslPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    distro: @jsonx.optional(fields, path, "distro"),
    engine: @jsonx.optional(fields, path, "engine"),
  }
}

///|
pub impl ToJson for StartPayload with fn to_json(self) {
  let fields : Map[String, Json] = { "task": self.task.to_json() }
  @jsonx.put_optional(fields, "api_key", self.api_key)
  @jsonx.put_optional(fields, "api_url", self.api_url)
  @jsonx.put_optional(fields, "model", self.model)
  @jsonx.put_optional(fields, "max_steps", self.max_steps)
  @jsonx.put_optional(fields, "session", self.session)
  @jsonx.put_optional(fields, "session_root", self.session_root)
  @jsonx.put_optional(fields, "workspace", self.workspace)
  @jsonx.put_optional(fields, "wsl", self.wsl)
  Json::object(fields)
}

///|
pub impl FromJson for StartPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    task: @jsonx.required(fields, path, "task"),
    api_key: @jsonx.optional(fields, path, "api_key"),
    api_url: @jsonx.optional(fields, path, "api_url"),
    model: @jsonx.optional(fields, path, "model"),
    max_steps: @jsonx.optional(fields, path, "max_steps"),
    session: @jsonx.optional(fields, path, "session"),
    session_root: @jsonx.optional(fields, path, "session_root"),
    workspace: @jsonx.optional(fields, path, "workspace"),
    wsl: @jsonx.optional(fields, path, "wsl"),
  }
}

///|
pub impl ToJson for StartReply with fn to_json(self) {
  {
    "run_id": self.run_id.to_json(),
    "status": self.status.to_json(),
    "exit_code": self.exit_code.to_json(),
  }
}

///|
pub impl FromJson for StartReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    run_id: @jsonx.required(fields, path, "run_id"),
    status: @jsonx.required(fields, path, "status"),
    exit_code: @jsonx.required(fields, path, "exit_code"),
  }
}

///|
pub impl ToJson for CancelPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([])
  @jsonx.put_optional(fields, "run_id", self.run_id)
  Json::object(fields)
}

///|
pub impl FromJson for CancelPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { run_id: @jsonx.optional(fields, path, "run_id") }
}

///|
pub impl ToJson for CancelReply with fn to_json(self) {
  let fields : Map[String, Json] = { "cancelled": self.cancelled.to_json() }
  @jsonx.put_optional(fields, "run_id", self.run_id)
  Json::object(fields)
}

///|
pub impl FromJson for CancelReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    cancelled: @jsonx.required(fields, path, "cancelled"),
    run_id: @jsonx.optional(fields, path, "run_id"),
  }
}

///|
pub impl ToJson for SteerPayload with fn to_json(self) {
  let fields : Map[String, Json] = { "text": self.text.to_json() }
  @jsonx.put_optional(fields, "run_id", self.run_id)
  Json::object(fields)
}

///|
pub impl FromJson for SteerPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    text: @jsonx.required(fields, path, "text"),
    run_id: @jsonx.optional(fields, path, "run_id"),
  }
}

///|
pub impl ToJson for SteerReply with fn to_json(self) {
  let fields : Map[String, Json] = { "steered": self.steered.to_json() }
  @jsonx.put_optional(fields, "run_id", self.run_id)
  Json::object(fields)
}

///|
pub impl FromJson for SteerReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    steered: @jsonx.required(fields, path, "steered"),
    // The frontend only uses `steered`. Preserve its previous decoder's
    // tolerance for a null or otherwise malformed advisory run id so that it
    // cannot turn a successful steer into an undelivered one.
    run_id: @jsonx.json_int(fields, "run_id"),
  }
}

///|
pub impl ToJson for CompactPayload with fn to_json(self) {
  let fields : Map[String, Json] = { "session": self.session.to_json() }
  @jsonx.put_optional(fields, "api_key", self.api_key)
  @jsonx.put_optional(fields, "api_url", self.api_url)
  @jsonx.put_optional(fields, "model", self.model)
  @jsonx.put_optional(fields, "max_steps", self.max_steps)
  @jsonx.put_optional(fields, "session_root", self.session_root)
  @jsonx.put_optional(fields, "workspace", self.workspace)
  @jsonx.put_optional(fields, "wsl", self.wsl)
  Json::object(fields)
}

///|
pub impl FromJson for CompactPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required(fields, path, "session"),
    api_key: @jsonx.optional(fields, path, "api_key"),
    api_url: @jsonx.optional(fields, path, "api_url"),
    model: @jsonx.optional(fields, path, "model"),
    max_steps: @jsonx.optional(fields, path, "max_steps"),
    session_root: @jsonx.optional(fields, path, "session_root"),
    workspace: @jsonx.optional(fields, path, "workspace"),
    wsl: @jsonx.optional(fields, path, "wsl"),
  }
}

///|
pub impl ToJson for CompactReply with fn to_json(self) {
  { "compacting": self.compacting.to_json() }
}

///|
pub impl FromJson for CompactReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { compacting: @jsonx.required(fields, path, "compacting") }
}

///|
pub impl ToJson for ConnectReply with fn to_json(self) {
  { "disconnected": self.disconnected.to_json() }
}

///|
pub impl FromJson for ConnectReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { disconnected: @jsonx.required(fields, path, "disconnected") }
}

///|
pub impl ToJson for LoadSessionPayload with fn to_json(self) {
  let fields : Map[String, Json] = { "session": self.session.to_json() }
  @jsonx.put_optional(fields, "workspace", self.workspace)
  Json::object(fields)
}

///|
pub impl FromJson for LoadSessionPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required(fields, path, "session"),
    workspace: @jsonx.optional(fields, path, "workspace"),
  }
}

///|
pub impl ToJson for SessionGroup with fn to_json(self) {
  {
    "workspace": self.workspace.to_json(),
    "name": self.name.to_json(),
    "session_root": self.session_root.to_json(),
    "sessions": self.sessions,
    "error": self.error.to_json(),
  }
}

///|
pub impl FromJson for SessionGroup with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  guard fields.get("sessions") is Some(Array(_) as sessions) else {
    return @jsonx.decode_error(path.add_key("sessions"), "expected array")
  }
  {
    workspace: @jsonx.required_string(fields, path, "workspace"),
    name: @jsonx.required_string(fields, path, "name"),
    session_root: if fields.get("session_root") is Some(String(value)) {
      value
    } else {
      ""
    },
    sessions,
    error: if fields.get("error") is Some(String(value)) {
      value
    } else {
      ""
    },
  }
}

///|
pub impl ToJson for SessionsReply with fn to_json(self) {
  { "groups": self.groups.to_json() }
}

///|
pub impl FromJson for SessionsReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let groups : Array[SessionGroup] = @jsonx.tolerant_rows(
    fields, path, "groups",
  )
  { groups, }
}

///|
pub impl ToJson for LoadSessionReply with fn to_json(self) {
  { "session": self.session }
}

///|
pub impl FromJson for LoadSessionReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  guard fields.get("session") is Some(session) else {
    return @jsonx.decode_error(path.add_key("session"), "expected field")
  }
  { session, }
}
