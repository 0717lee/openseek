// Explicit codecs for requests that can start an OpenSeek engine process.
// Unknown fields are ignored for forward evolution. Optional fields accept
// missing or null and are omitted when encoded; known malformed fields fail
// at their exact path instead of silently changing the engine configuration.

///|
fn JsonObject::optional_thinking(
  self : JsonObject,
  name : String,
) -> OpenSeekThinking? raise @json.JsonDecodeError {
  match self.fields.get(name) {
    Some(Null) | None => None
    Some(value) => Some(@json.from_json(value, path=self.path.add_key(name)))
  }
}

///|
pub impl FromJson for StartPayload with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "agent.start payload")
  {
    task: object.required_string("task"),
    submission_id: object.optional_string("submission_id"),
    model: object.optional_string("model"),
    thinking: object.optional_thinking("thinking"),
    max_steps: object.optional_int("max_steps"),
    session: object.required_string("session"),
    workspace: object.optional_string("workspace"),
  }
}

///|
pub impl ToJson for StartPayload with fn to_json(self) {
  let fields : Map[String, Json] = {
    "task": self.task.to_json(),
    "session": self.session.to_json(),
  }
  if self.submission_id is Some(submission_id) {
    fields["submission_id"] = submission_id.to_json()
  }
  if self.model is Some(model) {
    fields["model"] = model.to_json()
  }
  if self.thinking is Some(thinking) {
    fields["thinking"] = thinking.to_json()
  }
  if self.max_steps is Some(max_steps) {
    fields["max_steps"] = max_steps.to_json()
  }
  if self.workspace is Some(workspace) {
    fields["workspace"] = workspace.to_json()
  }
  Json::object(fields)
}

///|
pub impl FromJson for CompactPayload with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "agent.compact payload")
  {
    session: object.required_string("session"),
    model: object.optional_string("model"),
    thinking: object.optional_thinking("thinking"),
    max_steps: object.optional_int("max_steps"),
    workspace: object.optional_string("workspace"),
  }
}

///|
pub impl ToJson for CompactPayload with fn to_json(self) {
  let fields : Map[String, Json] = { "session": self.session.to_json() }
  if self.model is Some(model) {
    fields["model"] = model.to_json()
  }
  if self.thinking is Some(thinking) {
    fields["thinking"] = thinking.to_json()
  }
  if self.max_steps is Some(max_steps) {
    fields["max_steps"] = max_steps.to_json()
  }
  if self.workspace is Some(workspace) {
    fields["workspace"] = workspace.to_json()
  }
  Json::object(fields)
}

///|
pub impl FromJson for GoalPayload with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "agent.goal payload")
  {
    session: object.required_string("session"),
    text: object.optional_string("text"),
    auto: object.optional_bool("auto"),
    model: object.optional_string("model"),
    thinking: object.optional_thinking("thinking"),
    max_steps: object.optional_int("max_steps"),
    workspace: object.optional_string("workspace"),
  }
}

///|
pub impl ToJson for GoalPayload with fn to_json(self) {
  let fields : Map[String, Json] = { "session": self.session.to_json() }
  if self.text is Some(text) {
    fields["text"] = text.to_json()
  }
  if self.auto is Some(auto) {
    fields["auto"] = auto.to_json()
  }
  if self.model is Some(model) {
    fields["model"] = model.to_json()
  }
  if self.thinking is Some(thinking) {
    fields["thinking"] = thinking.to_json()
  }
  if self.max_steps is Some(max_steps) {
    fields["max_steps"] = max_steps.to_json()
  }
  if self.workspace is Some(workspace) {
    fields["workspace"] = workspace.to_json()
  }
  Json::object(fields)
}

///|
pub impl FromJson for OpenSeekThinking with fn from_json(json, path) {
  guard json is String(value) else {
    raise JsonDecodeError((path, "expected no, high, or max"))
  }
  guard OpenSeekThinking::parse(value) is Some(thinking) else {
    raise JsonDecodeError((path, "expected no, high, or max"))
  }
  thinking
}

///|
pub impl ToJson for OpenSeekThinking with fn to_json(self) {
  Json::string(self.wire())
}
