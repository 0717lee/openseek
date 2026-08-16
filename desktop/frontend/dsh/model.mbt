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
/// One WebSocket running-state observation and the local reducer generation
/// that received it. session.list replies use this to retain only events that
/// arrived after their request began.
priv struct DshSessionStatusObservation {
  session_id : String
  running : Bool
  generation : Int
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
priv struct DshModelSelection {
  provider : String
  model : String
  reasoning_effort : String?
} derive(Debug, Eq)

///|
priv struct DshModelOption {
  selection : DshModelSelection
  label : String
} derive(Eq)

///|
priv enum DshModels {
  DshModelsIdle
  DshModelsLoading(session_id~ : String)
  DshModelsReady(
    session_id~ : String,
    options~ : Array[DshModelOption],
    selected~ : DshModelSelection,
    routable~ : Bool
  )
  DshModelsSelecting(
    session_id~ : String,
    options~ : Array[DshModelOption],
    selected~ : DshModelSelection,
    routable~ : Bool,
    requested~ : DshModelSelection
  )
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
  DshSessionsReply(status_generation~ : Int)
  DshCreateReply(Int)
  DshHistoryReply(String)
  DshModelsReply(String)
  DshSelectModelReply(session_id~ : String)
  DshPromptWorkspaceReply(
    session_id~ : String,
    generation~ : Int,
    project~ : String,
    worktree_path~ : String
  )
  DshPromptMoveReply(
    session_id~ : String,
    generation~ : Int,
    project~ : String,
    worktree_path~ : String
  )
  DshPromptWorkspacesReply(
    session_id~ : String,
    generation~ : Int,
    worktree_path~ : String
  )
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
  ComposerAction(@composer.Action)
  ToggleWorktreeMode
  ModelChanged(String)
  WorktreeReady(
    session_id~ : String,
    generation~ : Int,
    project~ : String,
    name~ : String,
    created~ : Bool,
    path~ : String
  )
  WorktreeReleaseFailed(
    visible_session~ : String?,
    generation~ : Int,
    message~ : String
  )
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
/// Route the shared composer's deliberate operations back into dsh. Raw
/// keystrokes and completion navigation remain inside the composer package.
pub fn Msg::composer_action(action : @composer.Action) -> Msg {
  ComposerAction(action)
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
  // HTTP session snapshots and WebSocket status events use independent
  // carriers. Record the latest event per session so a late snapshot cannot
  // roll back a status that arrived after that snapshot request began.
  session_statuses : Array[DshSessionStatusObservation]
  session_status_generation : Int
  active_id : String?
  events : Array[DshEventRecord]
  streaming : String
  models : DshModels
  placement : @composer.WorktreeChoice
  // The main project captured when Worktree mode is chosen. Keep it through
  // retries after dsh moves the blank session into the generated Workspace.
  worktree_project : String?
  // The last root-authored submission snapshot. Unsent keystrokes live only
  // in the shared composer component and are cached there per session id.
  draft : String
  pending : Array[DshPendingInteraction]
  // Actor generations order page-attach snapshots against live mux events.
  // Selection and prompt generations keep older request replies from
  // overwriting later navigation or settling a newer send.
  pending_generation : Int
  selection_generation : Int
  // Session creation can span workspace.create and session.create. Keep that
  // chain busy independently from status events until its final reply settles.
  creation_pending : Bool
  prompt_generation : Int
  prompt_pending_session : String?
  // Cancellations settle over HTTP independently from running-status events.
  // Keep every originating session busy until its matching reply arrives;
  // navigation can start another cancellation before the first one settles.
  cancel_pending_sessions : Array[String]
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
    session_statuses: [],
    session_status_generation: 0,
    active_id: None,
    events: [],
    streaming: "",
    models: DshModelsIdle,
    placement: @composer.LocalCheckout,
    worktree_project: None,
    draft: "",
    pending: [],
    pending_generation: 0,
    selection_generation: 0,
    creation_pending: false,
    prompt_generation: 0,
    prompt_pending_session: None,
    cancel_pending_sessions: [],
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
  self.models.busy() ||
  self.creation_pending ||
  self.prompt_pending_session is Some(_) ||
  (self.active_id is Some(id) && self.cancel_pending_sessions.contains(id)) ||
  self.pending
  .iter()
  .any(item => {
    self.active_id == Some(item.session_id()) &&
    self.response_pending_rpcs.contains(item.rpc_id())
  })
}

///|
/// The worktree setup requests are one logical prompt submission. Keeping the
/// origin on the reply type lets every stage share the same navigation and
/// retry fence as the final session.prompt request.
fn DshReplyKind::prompt_origin(self : DshReplyKind) -> (String, Int)? {
  match self {
    DshPromptWorkspaceReply(session_id~, generation~, ..)
    | DshPromptMoveReply(session_id~, generation~, ..)
    | DshPromptWorkspacesReply(session_id~, generation~, ..)
    | DshPromptReply(session_id~, generation~, ..) =>
      Some((session_id, generation))
    _ => None
  }
}

///|
fn DshReplyKind::model_session(self : DshReplyKind) -> String? {
  match self {
    DshModelsReply(session_id) | DshSelectModelReply(session_id~) =>
      Some(session_id)
    _ => None
  }
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
fn DshModelSelection::key(self : DshModelSelection) -> String {
  Json::array([
    Json::string(self.provider),
    Json::string(self.model),
    match self.reasoning_effort {
      Some(value) => Json::string(value)
      None => Json::null()
    },
  ]).stringify()
}

///|
fn DshModelSelection::decode(value : Json) -> DshModelSelection? {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "provider") is Some(provider) &&
    @jsonx.json_text(fields, "model") is Some(model) else {
    return None
  }
  Some({
    provider,
    model,
    reasoning_effort: @jsonx.json_text(fields, "reasoningEffort"),
  })
}

///|
/// Fallback text for a current selection absent from dsh's advisory catalog.
fn DshModelSelection::label(self : DshModelSelection) -> String {
  let effort = match self.reasoning_effort {
    Some(value) => " · " + value
    None => ""
  }
  self.provider + " / " + self.model + effort
}

///|
fn DshModels::busy(self : DshModels) -> Bool {
  self is DshModelsLoading(..) || self is DshModelsSelecting(..)
}

///|
fn DshModels::routable(self : DshModels, session_id : String) -> Bool {
  match self {
    DshModelsReady(session_id=current, routable~, ..)
    | DshModelsSelecting(session_id=current, routable~, ..) =>
      current == session_id && routable
    DshModelsIdle | DshModelsLoading(..) => false
  }
}

///|
fn DshModels::decode(session_id : String, value : Json) -> DshModels? {
  guard value is Object(fields) &&
    fields.get("current") is Some(current_json) &&
    DshModelSelection::decode(current_json) is Some(selected) &&
    @jsonx.json_bool(fields, "routable") is Some(routable) &&
    fields.get("groups") is Some(Array(groups)) else {
    return None
  }
  let options : Array[DshModelOption] = []
  for group in groups {
    guard group is Object(group_fields) &&
      @jsonx.json_text(group_fields, "id") is Some(provider) &&
      @jsonx.json_text(group_fields, "name") is Some(provider_name) &&
      group_fields.get("models") is Some(Array(models)) else {
      continue
    }
    for model in models {
      guard model is Object(model_fields) &&
        @jsonx.json_text(model_fields, "id") is Some(model_id) &&
        @jsonx.json_text(model_fields, "name") is Some(model_name) else {
        continue
      }
      let base_label = provider_name + " / " + model_name
      options.push({
        selection: { provider, model: model_id, reasoning_effort: None },
        label: base_label,
      })
      if model_fields.get("reasoning") is Some(Object(reasoning)) &&
        reasoning.get("efforts") is Some(Array(efforts)) {
        for effort in efforts {
          guard effort is Object(effort_fields) &&
            @jsonx.json_text(effort_fields, "id") is Some(effort_id) &&
            @jsonx.json_text(effort_fields, "name") is Some(effort_name) else {
            continue
          }
          options.push({
            selection: {
              provider,
              model: model_id,
              reasoning_effort: Some(effort_id),
            },
            label: base_label + " · " + effort_name,
          })
        }
      }
    }
  }
  if !options.iter().any(option => option.selection.key() == selected.key()) {
    options.push({ selection: selected, label: selected.label() })
  }
  Some(DshModelsReady(session_id~, options~, selected~, routable~))
}

///|
fn DshModels::option(
  self : DshModels,
  session_id : String,
  key : String,
) -> DshModelOption? {
  match self {
    DshModelsReady(session_id=current, options~, ..) =>
      if current == session_id {
        options.iter().find_first(option => option.selection.key() == key)
      } else {
        None
      }
    DshModelsIdle | DshModelsLoading(..) | DshModelsSelecting(..) => None
  }
}

///|
fn DshModels::selecting(
  self : DshModels,
  session_id : String,
  requested : DshModelSelection,
) -> DshModels {
  match self {
    DshModelsReady(session_id=current, options~, selected~, routable~) =>
      if current == session_id {
        DshModelsSelecting(
          session_id~,
          options~,
          selected~,
          routable~,
          requested~,
        )
      } else {
        self
      }
    _ => self
  }
}

///|
fn DshModels::failed(self : DshModels, session_id : String) -> DshModels {
  match self {
    DshModelsLoading(session_id=current) if current == session_id =>
      DshModelsIdle
    DshModelsSelecting(session_id=current, options~, selected~, routable~, ..) if current ==
      session_id => DshModelsReady(session_id~, options~, selected~, routable~)
    _ => self
  }
}

///|
/// A successful selection keeps the catalog that rendered the picker and
/// replaces only dsh's authoritative current value.
fn DshModels::selected(
  self : DshModels,
  session_id : String,
  selected : DshModelSelection,
) -> DshModels? {
  match self {
    DshModelsSelecting(session_id=current, options~, ..) =>
      if current == session_id {
        let options = options.copy()
        if !options
          .iter()
          .any(option => option.selection.key() == selected.key()) {
          options.push({ selection: selected, label: selected.label() })
        }
        // dsh validates the route before accepting selection, so a successful
        // selectModel reply is routable even when the previous choice was not.
        Some(DshModelsReady(session_id~, options~, selected~, routable=true))
      } else {
        None
      }
    _ => None
  }
}

///|
fn State::active_row(self : State) -> DshSessionRow? {
  guard self.active_id is Some(id) else { return None }
  self.sessions.iter().find_first(row => row.id == id)
}

///|
fn State::active_blank(self : State) -> Bool {
  self.active_row().map(row => row.blank).unwrap_or(false)
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

///|
test "dsh model catalog keeps provider model and reasoning effort distinct" {
  guard DshModels::decode("session-1", {
      "current": {
        "provider": "deepseek",
        "model": "reasoner",
        "reasoningEffort": "high",
      },
      "routable": true,
      "groups": [
        {
          "id": "deepseek",
          "name": "DeepSeek",
          "models": [
            {
              "id": "reasoner",
              "name": "Reasoner",
              "reasoning": {
                "efforts": [
                  { "id": "low", "name": "Low" },
                  { "id": "high", "name": "High" },
                ],
              },
            },
          ],
        },
      ],
    })
    is Some(DshModelsReady(options~, selected~, routable~, ..)) else {
    fail("expected decoded dsh model catalog")
  }
  assert_true(routable)
  assert_eq(options.length(), 3)
  assert_eq(options[0].label, "DeepSeek / Reasoner")
  assert_eq(options[2].label, "DeepSeek / Reasoner · High")
  assert_eq(options[2].selection, selected)
  assert_false(options[0].selection.key() == options[2].selection.key())
}
