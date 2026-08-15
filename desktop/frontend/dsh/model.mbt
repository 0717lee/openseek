// DeepSeek Harness page state. The host owns process and transport lifetime;
// this package owns only the browser projection of dsh sessions and events.

///|
priv enum DshConnection {
  DshStarting
  DshReady
  DshUnavailable(String)
} derive(Eq)

///|
priv struct DshSessionRow {
  id : String
  title : String
  cwd : String?
  running : Bool
  blank : Bool
} derive(Eq)

///|
/// One durable dsh Workspace. Its canonical path and explicit session account
/// come from `workspace.list`; the frontend never reconstructs membership from
/// the session's display-only cwd.
priv struct DshWorkspaceRow {
  id : String
  title : String
  path : String
  session_ids : Array[String]
} derive(Eq)

///|
priv struct DshEventRecord {
  type_ : String
  seq : Int
  time : Double?
  data : Json
  // Surface replacements are model-context copies. The human transcript
  // keeps append-origin messages and never renders those copies twice.
  surface_append : Bool?
} derive(Eq)

///|
priv struct DshQuestionOption {
  label : String
  description : String
} derive(Eq)

///|
priv struct DshQuestion {
  id : String
  header : String
  question : String
  detail : String
  options : Array[DshQuestionOption]
  multi_select : Bool
} derive(Eq)

///|
priv struct DshQuestionAnswer {
  selected : Array[String]
  custom : String
} derive(Eq)

///|
priv enum DshPendingInteraction {
  DshApproval(
    rpc_id~ : String,
    session_id~ : String,
    approval_id~ : String,
    tool_name~ : String,
    reason~ : String
  )
  DshQuestions(
    rpc_id~ : String,
    session_id~ : String,
    questions~ : Array[DshQuestion],
    answers~ : Map[String, DshQuestionAnswer]
  )
} derive(Eq)

///|
priv enum DshReplyKind {
  DshStatusReply
  DshPendingReply
  DshReconnectReply
  DshWorkspacesReply
  DshWorkspaceCreateReply(Int)
  DshSessionsReply
  DshCreateReply(Int)
  DshHistoryReply(String)
  DshPromptReply(session_id~ : String, draft~ : String, generation~ : Int)
  DshCancelReply(String)
  DshResponseReply(rpc_id~ : String, session_id~ : String)
}

///|
enum Msg {
  Refresh
  NewSession(String?)
  NewWorkspaceSession(String)
  OpenSession(String)
  DraftChanged(String)
  Send
  Stop
  ApprovalDecision(rpc_id~ : String, outcome~ : String)
  QuestionOption(rpc_id~ : String, question_id~ : String, label~ : String)
  QuestionCustom(rpc_id~ : String, question_id~ : String, value~ : String)
  SubmitQuestions(String)
  Reply(kind~ : DshReplyKind, value~ : Json)
  Failed(kind~ : DshReplyKind, message~ : String)
  StatusChanged(Json)
  Event(Json)
}

///|
pub fn Msg::refresh() -> Msg {
  Refresh
}

///|
pub fn Msg::new_session(workspace_id : String?) -> Msg {
  NewSession(workspace_id)
}

///|
/// Register one local directory in dsh, then create the first session through
/// the returned Workspace id. Used only when dsh has no registered Workspace
/// and OpenSeek already has an explicit local project selection.
pub fn Msg::new_workspace_session(path : String) -> Msg {
  NewWorkspaceSession(path)
}

///|
pub fn Msg::open_session(session_id : String) -> Msg {
  OpenSession(session_id)
}

///|
pub fn Msg::status_changed(value : Json) -> Msg {
  StatusChanged(value)
}

///|
pub fn Msg::event(value : Json) -> Msg {
  Event(value)
}

///|
struct State {
  connection : DshConnection
  workspaces : Array[DshWorkspaceRow]
  sessions : Array[DshSessionRow]
  active_id : String?
  events : Array[DshEventRecord]
  streaming : String
  draft : String
  pending : Array[DshPendingInteraction]
  // Actor generations order page-attach snapshots against live mux events.
  // Selection and prompt generations keep older request replies from
  // overwriting later navigation or settling a newer send.
  pending_generation : Int
  selection_generation : Int
  prompt_generation : Int
  prompt_pending_session : String?
  // A session-status event can arrive before the HTTP response that settles an
  // approval or question. Keep the originating RPC busy independently so its
  // card cannot submit the same response twice during that interval.
  response_pending_rpcs : Array[String]
  loading : Bool
  notice : String
} derive(Eq)

///|
pub fn State::State(loading? : Bool = false) -> State {
  {
    connection: DshStarting,
    workspaces: [],
    sessions: [],
    active_id: None,
    events: [],
    streaming: "",
    draft: "",
    pending: [],
    pending_generation: 0,
    selection_generation: 0,
    prompt_generation: 0,
    prompt_pending_session: None,
    response_pending_rpcs: [],
    loading,
    notice: "",
  }
}

///|
pub fn State::can_create(self : State) -> Bool {
  self.connection is DshReady && !self.busy()
}

///|
/// HTTP prompt/interaction settlement and background session lifecycle updates
/// are independent. Keep the active composer disabled until its page work and
/// accepted requests have settled.
fn State::busy(self : State) -> Bool {
  self.loading ||
  self.prompt_pending_session is Some(_) ||
  self.pending
  .iter()
  .any(item => {
    self.active_id == Some(item.session_id()) &&
    self.response_pending_rpcs.contains(item.rpc_id())
  })
}

///|
pub fn State::has_active(self : State) -> Bool {
  self.active_id is Some(_)
}

///|
/// The transcript component re-pins on an accepted local prompt before dsh's
/// durable user event arrives. This generation advances only in `Send`.
pub fn State::submission_generation(self : State) -> Int {
  self.prompt_generation
}

///|
/// The root Desktop model uses connection failures for its shared toast
/// queue. Keeping this as plain data lets the dsh update remain pure and lets
/// the root suppress duplicate notifications from status polling.
pub fn State::unavailable_message(self : State) -> String? {
  match self.connection {
    DshUnavailable(message) => Some(message)
    DshStarting | DshReady => None
  }
}

///|
/// The selected dsh session namespaces the shared keyed transcript renderer.
pub fn State::active_id(self : State) -> String? {
  self.active_id
}

///|
fn State::active_workspace_row(self : State) -> DshWorkspaceRow? {
  guard self.active_id is Some(session_id) else { return None }
  self.workspaces
  .iter()
  .find_first(workspace => workspace.session_ids.contains(session_id))
}

///|
/// The dsh Workspace currently owning the selected session. The global add
/// action falls back to the first registered Workspace when no session is
/// selected, while Editor and Terminal use `active_workspace_path` and thus
/// require an actual session membership.
pub fn State::preferred_workspace_id(self : State) -> String? {
  if self.active_workspace_row() is Some(workspace) {
    Some(workspace.id)
  } else {
    self.workspaces.get(0).map(workspace => workspace.id)
  }
}

///|
/// Canonical local directory of the dsh Workspace that owns the active
/// session. This value was normalized and membership-checked by dsh itself.
pub fn State::active_workspace_path(self : State) -> String? {
  self.active_workspace_row().map(workspace => workspace.path)
}

///|
fn State::active_row(self : State) -> DshSessionRow? {
  guard self.active_id is Some(id) else { return None }
  self.sessions.iter().find_first(row => row.id == id)
}

///|
fn State::is_running(self : State) -> Bool {
  self.active_row().map(row => row.running).unwrap_or(false)
}

///|
fn State::connection_label(self : State) -> String {
  match self.connection {
    DshStarting => "Starting DeepSeek Harness"
    DshReady => "DeepSeek Harness"
    DshUnavailable(_) => "DeepSeek Harness unavailable"
  }
}

///|
fn State::active_title(self : State) -> String {
  self.active_row().map(row => row.title).unwrap_or("DeepSeek Harness")
}

///|
priv struct DshEnvelope(Json)

///|
/// `/api/respond` returns a receipt rather than a normal server-response.
/// Keeping it distinct prevents a rejected or duplicate answer from removing
/// the still-actionable interaction card.
priv struct DshResponseReceipt(Json)

///|
fn DshResponseReceipt::accepted(self : DshResponseReceipt) -> Bool {
  self.0 is Object(fields) && fields.get("accepted") is Some(True)
}

///|
fn DshResponseReceipt::error(self : DshResponseReceipt) -> String {
  guard self.0 is Object(fields) else {
    return "DeepSeek Harness returned a malformed response receipt"
  }
  let reason = @jsonx.json_text(fields, "reason").unwrap_or("response-rejected")
  "DeepSeek Harness rejected the response: " + reason
}

///|
fn DshEnvelope::value(self : DshEnvelope) -> Json? {
  guard self.0 is Object(fields) &&
    fields.get("type") is Some(String("server-response")) &&
    fields.get("result") is Some(Object(result)) &&
    result.get("ok") is Some(True) else {
    return None
  }
  result.get("value")
}

///|
fn DshEnvelope::error(self : DshEnvelope) -> String {
  guard self.0 is Object(fields) &&
    fields.get("result") is Some(Object(result)) &&
    result.get("error") is Some(Object(error)) else {
    return "DeepSeek Harness returned a malformed response"
  }
  let code = @jsonx.json_text(error, "code").unwrap_or("request-failed")
  let message = @jsonx.json_text(error, "message").unwrap_or("Request failed")
  "\{code}: \{message}"
}

///|
fn DshSessionRow::decode(value : Json) -> DshSessionRow? {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "sessionId") is Some(id) else {
    return None
  }
  let title = match fields.get("projections") {
    Some(Object(projections)) =>
      match projections.get("values") {
        Some(Object(values)) =>
          match values.get("title") {
            Some(String(title)) if !title.trim().is_empty() => title
            _ => id
          }
        _ => id
      }
    _ => id
  }
  Some({
    id,
    title,
    cwd: @jsonx.json_text(fields, "cwd"),
    running: @jsonx.json_bool(fields, "running").unwrap_or(false),
    blank: @jsonx.json_bool(fields, "blank").unwrap_or(false),
  })
}

///|
fn DshWorkspaceRow::decode(value : Json) -> DshWorkspaceRow? {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "workspaceId") is Some(id) &&
    @jsonx.json_text(fields, "title") is Some(title) &&
    @jsonx.json_text(fields, "path") is Some(path) else {
    return None
  }
  let session_ids : Array[String] = []
  if fields.get("sessionIds") is Some(Array(values)) {
    for value in values {
      if value is String(session_id) {
        session_ids.push(session_id)
      }
    }
  }
  Some({ id, title, path, session_ids })
}

///|
fn DshEventRecord::decode(value : Json) -> DshEventRecord? {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "type") is Some(type_) &&
    @jsonx.json_int(fields, "seq") is Some(seq) &&
    fields.get("data") is Some(data) else {
    return None
  }
  let time = match fields.get("time") {
    Some(Number(value, ..)) => Some(value)
    _ => None
  }
  let surface_append = match fields.get("surfaceOp") {
    Some(String("append")) => Some(true)
    Some(Object(op)) if @jsonx.json_text(op, "op") == Some("replace") =>
      Some(false)
    _ => None
  }
  Some({ type_, seq, time, data, surface_append })
}

///|
fn DshQuestion::decode(value : Json) -> DshQuestion? {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "id") is Some(id) &&
    @jsonx.json_text(fields, "question") is Some(question) else {
    return None
  }
  let options : Array[DshQuestionOption] = []
  if fields.get("options") is Some(Array(values)) {
    for value in values {
      if value is Object(option) &&
        @jsonx.json_text(option, "label") is Some(label) {
        options.push({
          label,
          description: @jsonx.json_text(option, "description").unwrap_or(""),
        })
      }
    }
  }
  Some({
    id,
    header: @jsonx.json_text(fields, "header").unwrap_or("Question"),
    question,
    detail: @jsonx.json_text(fields, "detail").unwrap_or(""),
    options,
    multi_select: @jsonx.json_bool(fields, "multiSelect").unwrap_or(false),
  })
}

///|
fn DshQuestionAnswer::empty() -> DshQuestionAnswer {
  { selected: [], custom: "" }
}
