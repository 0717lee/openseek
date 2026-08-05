// Codex app-server state for the dedicated Codex page. This deliberately does
// not reuse OpenSeek's Conversation: Codex owns its own durable thread/turn/item
// model, and `thread/read(includeTurns=true)` is the authoritative reconnect
// snapshot for that model.

///|
priv enum CodexConnection {
  CodexStarting
  CodexReady
  CodexUnavailable(String)
} derive(Eq)

///|
priv enum CodexAccount {
  CodexAccountUnknown
  CodexSignedOut(Bool)
  CodexSignedIn(kind~ : String, plan~ : String?)
} derive(Eq)

///|
priv struct CodexModelOption {
  id : String
  label : String
  is_default : Bool
} derive(Eq)

///|
priv struct CodexThreadRow {
  id : String
  title : String
  cwd : String?
} derive(Eq)

///|
priv struct CodexItem {
  id : String
  kind : String
  value : Json
  // Deltas are presentation-only. `item/completed` replaces `value` and
  // clears this field because the completed item is authoritative.
  streamed : String
} derive(Eq)

///|
priv struct CodexTurn {
  id : String
  status : String
  items : Array[CodexItem]
  error : String?
} derive(Eq)

///|
priv struct CodexThread {
  id : String
  title : String
  cwd : String?
  turns : Array[CodexTurn]
} derive(Eq)

///|
priv struct CodexQuestion {
  id : String
  header : String
  question : String
  options : Array[(String, String)]
}

///|
priv struct CodexPendingRequest {
  request_id : Json
  method_ : String
  params : Json
  // `item/tool/requestUserInput` keeps one answer per question. MCP form
  // elicitation uses the reserved `__content` entry as its JSON editor.
  answers : Map[String, String]
} derive(Eq)

///|
priv enum CodexReplyKind {
  CodexStatusReply
  CodexRequestsReply
  CodexAccountReply
  CodexModelsReply
  CodexThreadsReply
  CodexThreadReply
  CodexNewThreadReply
  CodexTurnReply
  CodexLoginReply
  CodexArchiveReply(String)
  CodexMutationReply
  CodexApprovalReply
}

///|
/// All Codex-local state transitions. The root frontend wraps this message as
/// one variant of its own Msg, but it never inspects app-server replies or
/// mutates Codex's account, thread, turn, item, or approval state directly.
enum Msg {
  Refresh
  DraftChanged(String)
  ModelChanged(String)
  StartThread(String)
  OpenThread(String)
  ArchiveThread(String)
  Send
  Stop
  Login
  CancelLogin
  Logout
  RequestAnswer(request_key~ : String, question_id~ : String, answer~ : String)
  Respond(request_key~ : String, decision~ : String)
  Reply(kind~ : CodexReplyKind, value~ : Json)
  Failed(kind~ : CodexReplyKind, message~ : String)
  StatusChanged(Json)
  Notification(method_~ : String, params~ : Json)
  ServerRequest(request_id~ : Json, method_~ : String, params~ : Json)
}

///|
/// Shell entrypoint for refreshing the focused Codex catalog.
pub fn Msg::refresh() -> Msg {
  Refresh
}

///|
/// Shell entrypoint for starting a task in an exact working directory.
pub fn Msg::start_thread(cwd : String) -> Msg {
  StartThread(cwd)
}

///|
/// Shell entrypoint for selecting a Codex sidebar row.
pub fn Msg::open_thread(thread_id : String) -> Msg {
  OpenThread(thread_id)
}

///|
/// Shell entrypoint for archiving a Codex sidebar row.
pub fn Msg::archive_thread(thread_id : String) -> Msg {
  ArchiveThread(thread_id)
}

///|
/// Decode-free boundary for the host's Codex readiness notification.
pub fn Msg::status_changed(value : Json) -> Msg {
  StatusChanged(value)
}

///|
/// Decode-free boundary for an app-server notification forwarded by the host.
pub fn Msg::notification(method_ : String, params : Json) -> Msg {
  Notification(method_~, params~)
}

///|
/// Decode-free boundary for an app-server request forwarded by the host.
pub fn Msg::server_request(
  request_id : Json,
  method_ : String,
  params : Json,
) -> Msg {
  ServerRequest(request_id~, method_~, params~)
}

///|
struct State {
  connection : CodexConnection
  account : CodexAccount
  login_id : String?
  auth_url : String?
  models : Array[CodexModelOption]
  selected_model : String
  threads : Array[CodexThreadRow]
  active : CodexThread?
  draft : String
  pending_requests : Array[CodexPendingRequest]
  loading : Bool
  notice : String
} derive(Eq)

///|
pub fn State::State(loading? : Bool = false) -> State {
  {
    connection: CodexStarting,
    account: CodexAccountUnknown,
    login_id: None,
    auth_url: None,
    models: [],
    selected_model: "",
    threads: [],
    active: None,
    draft: "",
    pending_requests: [],
    loading,
    notice: "",
  }
}

///|
/// Build state from the authoritative `thread/read(includeTurns=true)` reply.
/// The shell's black-box workspace tests use the same boundary as production
/// instead of constructing Codex's private thread representation.
pub fn State::from_thread_snapshot(value : Json) -> State {
  State().with_thread_reply(value)
}

///|
/// Whether the sidebar has any Codex conversations to lay out.
pub fn State::has_threads(self : State) -> Bool {
  !self.threads.is_empty()
}

///|
/// Whether a selected Codex task can own the terminal and file panels.
pub fn State::has_active(self : State) -> Bool {
  self.active is Some(_)
}

///|
/// The selected app-server thread id used as the host-panel owner.
pub fn State::active_id(self : State) -> String? {
  self.active.map(thread => thread.id)
}

///|
/// The selected task's exact app-server cwd. A missing cwd stays missing so
/// the shell never guesses an OpenSeek workspace for Codex file operations.
/// Bind the host path to the channel at this boundary: browser state must not
/// interpret a remote host path using the local machine's filesystem rules.
pub fn State::active_workspace(
  self : State,
  channel : @interop.ChannelId,
) -> @common.Uri? {
  match self.active {
    Some(thread) => thread.workspace(channel)
    None => None
  }
}

///|
/// Expose the draft as read-only text for shell-level integration tests.
pub fn State::draft_text(self : State) -> String {
  self.draft
}

///|
/// Append an editor comment to Codex's plain-text draft. Structured OpenSeek
/// mention chips belong to a different conversation protocol and never cross
/// this package boundary.
pub fn State::with_editor_comment(
  self : State,
  file : String,
  start_line : Int,
  end_line : Int,
  comment : String,
  quote : String,
) -> State {
  let selected = "File: \{file}:\{start_line}-\{end_line}\n" +
    "Comment: \{comment}\n\nSelected code:\n\{quote}"
  let draft = if self.draft.trim().is_empty() {
    selected
  } else {
    self.draft + "\n\n" + selected
  }
  { ..self, draft, }
}

///|
fn CodexItem::decode(value : Json) -> CodexItem? {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "id") is Some(id) &&
    @jsonx.json_text(fields, "type") is Some(kind) else {
    return None
  }
  Some({ id, kind, value, streamed: "" })
}

///|
fn CodexTurn::decode(value : Json) -> CodexTurn? {
  guard value is Object(fields) && @jsonx.json_text(fields, "id") is Some(id) else {
    return None
  }
  let items : Array[CodexItem] = []
  if fields.get("items") is Some(Array(values)) {
    for value in values {
      if CodexItem::decode(value) is Some(item) {
        items.push(item)
      }
    }
  }
  let error = match fields.get("error") {
    Some(Object(error)) => @jsonx.json_text(error, "message")
    _ => None
  }
  Some({
    id,
    status: @jsonx.json_text(fields, "status").unwrap_or("completed"),
    items,
    error,
  })
}

///|
fn CodexThread::decode(value : Json) -> CodexThread? {
  guard value is Object(fields) && @jsonx.json_text(fields, "id") is Some(id) else {
    return None
  }
  let turns : Array[CodexTurn] = []
  if fields.get("turns") is Some(Array(values)) {
    for value in values {
      if CodexTurn::decode(value) is Some(turn) {
        turns.push(turn)
      }
    }
  }
  Some({
    id,
    title: CodexThreadRow::title(fields),
    cwd: @jsonx.json_text(fields, "cwd"),
    turns,
  })
}

///|
/// The app-server thread's working directory is the Desktop workspace for
/// files and terminals. A missing or blank cwd is deliberately not guessed
/// from the Codex thread id: OpenSeek's host cannot derive a Codex directory
/// from that unrelated identifier.
fn CodexThread::workspace(
  self : CodexThread,
  channel : @interop.ChannelId,
) -> @common.Uri? {
  match self.cwd {
    Some(cwd) if !cwd.trim().is_empty() => @resource.of_path(channel, cwd)
    _ => None
  }
}

///|
fn CodexThreadRow::title(fields : Map[String, Json]) -> String {
  let title = @jsonx.json_text(fields, "name").unwrap_or("").trim().to_owned()
  if !title.is_empty() {
    return title
  }
  let preview = @jsonx.json_text(fields, "preview")
    .unwrap_or("")
    .trim()
    .to_owned()
  if preview.is_empty() {
    "New Codex thread"
  } else {
    preview
  }
}

///|
fn State::with_status(self : State, value : Json) -> State {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "status") is Some(status) else {
    return { ..self, connection: CodexUnavailable("Malformed status reply") }
  }
  {
    ..self,
    connection: match status {
      "ready" => CodexReady
      "starting" => CodexStarting
      _ =>
        CodexUnavailable(
          @jsonx.json_text(fields, "message").unwrap_or("Codex is unavailable"),
        )
    },
  }
}

///|
fn State::with_account(self : State, value : Json) -> State {
  guard value is Object(fields) else {
    return { ..self, notice: "Malformed Codex account reply" }
  }
  let requires_auth = fields.get("requiresOpenaiAuth") is Some(True)
  let account = match fields.get("account") {
    Some(Object(account)) =>
      CodexSignedIn(
        kind=@jsonx.json_text(account, "type").unwrap_or("Codex"),
        plan=@jsonx.json_text(account, "planType"),
      )
    _ => CodexSignedOut(requires_auth)
  }
  // A fresh account snapshot settles both successful and cancelled login
  // attempts. Do not leave an obsolete browser URL actionable afterward.
  { ..self, account, login_id: None, auth_url: None, notice: "" }
}

///|
fn State::with_models(self : State, value : Json) -> State {
  guard value is Object(fields) && fields.get("data") is Some(Array(values)) else {
    return { ..self, notice: "Malformed Codex model list" }
  }
  let models : Array[CodexModelOption] = []
  let mut default_model = ""
  for value in values {
    guard value is Object(model) && @jsonx.json_text(model, "id") is Some(id) else {
      continue
    }
    let is_default = model.get("isDefault") is Some(True)
    if is_default {
      default_model = id
    }
    models.push({
      id,
      label: @jsonx.json_text(model, "displayName").unwrap_or(id),
      is_default,
    })
  }
  let selected_model = if self.selected_model.is_empty() ||
    !models.iter().any(model => model.id == self.selected_model) {
    if !default_model.is_empty() {
      default_model
    } else {
      models.get(0).map(model => model.id).unwrap_or("")
    }
  } else {
    self.selected_model
  }
  { ..self, models, selected_model, notice: "" }
}

///|
fn State::with_threads(self : State, value : Json) -> State {
  guard value is Object(fields) && fields.get("data") is Some(Array(values)) else {
    return { ..self, notice: "Malformed Codex thread list" }
  }
  let threads : Array[CodexThreadRow] = []
  for value in values {
    guard value is Object(thread) && @jsonx.json_text(thread, "id") is Some(id) else {
      continue
    }
    threads.push({
      id,
      title: CodexThreadRow::title(thread),
      cwd: @jsonx.json_text(thread, "cwd"),
    })
  }
  // A just-started thread may not be present in the first state-DB page yet,
  // especially when the 100-row catalog is full. Its `thread/start` reply is
  // newer and authoritative, so do not let an older list snapshot erase the
  // active row from the navigation rail.
  let visible = if self.active is Some(active) &&
    !threads.iter().any(thread => thread.id == active.id) {
    let visible : Array[CodexThreadRow] = [
      { id: active.id, title: active.title, cwd: active.cwd },
    ]
    for thread in threads {
      visible.push(thread)
    }
    visible
  } else {
    threads
  }
  { ..self, threads: visible, notice: "" }
}

///|
fn State::with_requests(self : State, value : Json) -> State {
  guard value is Object(fields) && fields.get("data") is Some(Array(values)) else {
    return { ..self, notice: "Malformed Codex request list" }
  }
  let pending_requests : Array[CodexPendingRequest] = []
  for value in values {
    guard value is Object(request) &&
      request.get("request_id") is Some(request_id) &&
      @jsonx.json_text(request, "method") is Some(method_) &&
      request.get("params") is Some(params) else {
      continue
    }
    // Preserve edits for a request already shown while replacing the list
    // with the actor's exact live ownership snapshot.
    let key = request_id.stringify()
    let mut answers : Map[String, String] = Map([])
    for existing in self.pending_requests {
      if existing.request_id.stringify() == key {
        answers = existing.answers
        break
      }
    }
    pending_requests.push({ request_id, method_, params, answers })
  }
  { ..self, pending_requests, }
}

///|
fn State::with_thread_reply(self : State, value : Json) -> State {
  guard value is Object(fields) &&
    fields.get("thread") is Some(thread) &&
    CodexThread::decode(thread) is Some(active) else {
    return { ..self, loading: false, notice: "Malformed Codex thread reply" }
  }
  // `thread/start` is authoritative even before the catalog refresh returns.
  // Keep the active thread visible immediately; the following list reply can
  // replace its provisional title with persisted metadata.
  let threads : Array[CodexThreadRow] = [
    { id: active.id, title: active.title, cwd: active.cwd },
  ]
  for thread in self.threads {
    if thread.id != active.id {
      threads.push(thread)
    }
  }
  { ..self, threads, active: Some(active), loading: false, notice: "" }
}

///|
fn State::without_thread(self : State, thread_id : String) -> State {
  {
    ..self,
    threads: self.threads.filter(thread => thread.id != thread_id),
    active: match self.active {
      Some(active) if active.id == thread_id => None
      other => other
    },
  }
}

///|
fn State::with_login(self : State, value : Json) -> State {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "loginId") is Some(login_id) &&
    @jsonx.json_text(fields, "authUrl") is Some(auth_url) else {
    return { ..self, loading: false, notice: "Malformed Codex login reply" }
  }
  { ..self, login_id: Some(login_id), auth_url: Some(auth_url), loading: false }
}

///|
fn State::is_running(self : State) -> Bool {
  guard self.active is Some(active) else { return false }
  active.turns.iter().any(turn => turn.status == "inProgress")
}

///|
fn State::active_turn_id(self : State) -> String? {
  guard self.active is Some(active) else { return None }
  for index = active.turns.length() - 1; index >= 0; index = index - 1 {
    if active.turns[index].status == "inProgress" {
      return Some(active.turns[index].id)
    }
  }
  None
}

///|
fn CodexTurn::with_item(
  self : CodexTurn,
  item : CodexItem,
  completed~ : Bool,
) -> CodexTurn {
  let mut found = false
  let items = self.items.map(existing => {
    if existing.id == item.id {
      found = true
      if completed {
        item
      } else {
        { ..item, streamed: existing.streamed }
      }
    } else {
      existing
    }
  })
  if !found {
    items.push(item)
  }
  { ..self, items, }
}

///|
fn CodexTurn::with_delta(
  self : CodexTurn,
  item_id : String,
  delta : String,
) -> CodexTurn {
  {
    ..self,
    items: self.items.map(item => {
      if item.id == item_id {
        { ..item, streamed: item.streamed + delta }
      } else {
        item
      }
    }),
  }
}

///|
fn CodexThread::with_turn(self : CodexThread, turn : CodexTurn) -> CodexThread {
  let mut found = false
  let turns = self.turns.map(existing => {
    if existing.id == turn.id {
      found = true
      turn
    } else {
      existing
    }
  })
  if !found {
    turns.push(turn)
  }
  { ..self, turns, }
}

///|
fn CodexThread::with_item(
  self : CodexThread,
  turn_id : String,
  item : CodexItem,
  completed~ : Bool,
) -> CodexThread {
  let mut found = false
  let turns = self.turns.map(turn => {
    if turn.id == turn_id {
      found = true
      turn.with_item(item, completed~)
    } else {
      turn
    }
  })
  if !found {
    turns.push({ id: turn_id, status: "inProgress", items: [item], error: None })
  }
  { ..self, turns, }
}

///|
fn CodexThread::with_delta(
  self : CodexThread,
  turn_id : String,
  item_id : String,
  delta : String,
) -> CodexThread {
  {
    ..self,
    turns: self.turns.map(turn => {
      if turn.id == turn_id {
        turn.with_delta(item_id, delta)
      } else {
        turn
      }
    }),
  }
}

///|
fn State::with_notification(
  self : State,
  method_ : String,
  params : Json,
) -> State {
  guard params is Object(fields) else { return self }
  if method_ == "serverRequest/resolved" &&
    fields.get("requestId") is Some(request_id) {
    let key = request_id.stringify()
    return {
      ..self,
      pending_requests: self.pending_requests.filter(request => {
        request.request_id.stringify() != key
      }),
    }
  }
  if method_ == "thread/archived" &&
    @jsonx.json_text(fields, "threadId") is Some(thread_id) {
    return self.without_thread(thread_id)
  }
  guard self.active is Some(active) &&
    @jsonx.json_text(fields, "threadId").unwrap_or(active.id) == active.id else {
    return self
  }
  match method_ {
    "thread/name/updated" =>
      if @jsonx.json_text(fields, "name") is Some(title) {
        { ..self, active: Some({ ..active, title, }) }
      } else {
        self
      }
    "turn/started" | "turn/completed" =>
      if fields.get("turn") is Some(value) &&
        CodexTurn::decode(value) is Some(turn) {
        { ..self, active: Some(active.with_turn(turn)) }
      } else {
        self
      }
    "item/started" | "item/completed" =>
      if @jsonx.json_text(fields, "turnId") is Some(turn_id) &&
        fields.get("item") is Some(value) &&
        CodexItem::decode(value) is Some(item) {
        {
          ..self,
          active: Some(
            active.with_item(
              turn_id,
              item,
              completed=method_ == "item/completed",
            ),
          ),
        }
      } else {
        self
      }
    "item/agentMessage/delta"
    | "item/plan/delta"
    | "item/reasoning/summaryTextDelta"
    | "item/reasoning/textDelta"
    | "item/commandExecution/outputDelta" =>
      if @jsonx.json_text(fields, "turnId") is Some(turn_id) &&
        @jsonx.json_text(fields, "itemId") is Some(item_id) &&
        @jsonx.json_text(fields, "delta") is Some(delta) {
        { ..self, active: Some(active.with_delta(turn_id, item_id, delta)) }
      } else {
        self
      }
    "error" =>
      if fields.get("error") is Some(Object(error)) &&
        @jsonx.json_text(error, "message") is Some(message) {
        { ..self, notice: message }
      } else {
        self
      }
    "warning" =>
      if @jsonx.json_text(fields, "message") is Some(message) {
        { ..self, notice: message }
      } else {
        self
      }
    _ => self
  }
}

///|
fn State::with_pending_request(
  self : State,
  request_id : Json,
  method_ : String,
  params : Json,
) -> State {
  let key = request_id.stringify()
  if self.pending_requests
    .iter()
    .any(request => request.request_id.stringify() == key) {
    return self
  }
  let pending_requests = self.pending_requests.copy()
  pending_requests.push({ request_id, method_, params, answers: Map([]) })
  { ..self, pending_requests, }
}

///|
fn State::with_request_answer(
  self : State,
  request_key : String,
  question_id : String,
  answer : String,
) -> State {
  {
    ..self,
    pending_requests: self.pending_requests.map(request => {
      if request.request_id.stringify() == request_key {
        let answers = request.answers.copy()
        answers[question_id] = answer
        { ..request, answers, }
      } else {
        request
      }
    }),
  }
}

///|
fn CodexPendingRequest::questions(
  self : CodexPendingRequest,
) -> Array[CodexQuestion] {
  guard self.params is Object(fields) &&
    fields.get("questions") is Some(Array(values)) else {
    return []
  }
  let questions : Array[CodexQuestion] = []
  for value in values {
    guard value is Object(question) &&
      @jsonx.json_text(question, "id") is Some(id) else {
      continue
    }
    let options : Array[(String, String)] = []
    if question.get("options") is Some(Array(values)) {
      for value in values {
        if value is Object(option) &&
          @jsonx.json_text(option, "label") is Some(label) {
          options.push(
            (label, @jsonx.json_text(option, "description").unwrap_or("")),
          )
        }
      }
    }
    questions.push({
      id,
      header: @jsonx.json_text(question, "header").unwrap_or("Question"),
      question: @jsonx.json_text(question, "question").unwrap_or(""),
      options,
    })
  }
  questions
}

///|
fn CodexPendingRequest::response(
  self : CodexPendingRequest,
  decision : String,
) -> Json? {
  match self.method_ {
    "item/commandExecution/requestApproval"
    | "item/fileChange/requestApproval" =>
      Some({ "decision": Json::string(decision) })
    "item/permissions/requestApproval" =>
      if decision == "decline" {
        Some({ "permissions": {}, "scope": "turn" })
      } else if self.params is Object(fields) &&
        fields.get("permissions") is Some(permissions) {
        Some({
          "permissions": permissions,
          "scope": if decision == "acceptForSession" {
            "session"
          } else {
            "turn"
          },
        })
      } else {
        None
      }
    "item/tool/requestUserInput" => {
      let answers : Map[String, Json] = Map([])
      for question in self.questions() {
        let text = self.answers.get(question.id).unwrap_or("").trim().to_owned()
        if text.is_empty() {
          return None
        }
        answers[question.id] = { "answers": [Json::string(text)] }
      }
      Some({ "answers": Json::object(answers) })
    }
    "mcpServer/elicitation/request" =>
      if decision == "decline" || decision == "cancel" {
        Some({ "action": Json::string(decision), "content": Json::null() })
      } else {
        let text = self.answers
          .get("__content")
          .unwrap_or("{}")
          .trim()
          .to_owned()
        let content = @json.parse(text) catch { _ => return None }
        Some({ "action": "accept", "content": content })
      }
    _ => None
  }
}

///|
fn CodexItem::text(self : CodexItem) -> String {
  let streamed = self.streamed
  guard self.value is Object(fields) else { return self.value.stringify() }
  match self.kind {
    "userMessage" => {
      let parts : Array[String] = []
      if fields.get("content") is Some(Array(values)) {
        for value in values {
          if value is Object(input) &&
            @jsonx.json_text(input, "text") is Some(text) {
            parts.push(text)
          }
        }
      }
      parts.join("\n")
    }
    "agentMessage" | "plan" => {
      let text = @jsonx.json_text(fields, "text").unwrap_or("")
      if text.is_empty() {
        streamed
      } else {
        text
      }
    }
    "reasoning" =>
      if !streamed.is_empty() {
        streamed
      } else {
        fields.get("summary").map(value => value.stringify()).unwrap_or("")
      }
    "commandExecution" => {
      let command = @jsonx.json_text(fields, "command").unwrap_or("Command")
      let output = @jsonx.json_text(fields, "aggregatedOutput").unwrap_or(
        streamed,
      )
      if output.is_empty() {
        command
      } else {
        command + "\n\n" + output
      }
    }
    "fileChange" =>
      fields
      .get("changes")
      .map(value => value.stringify())
      .unwrap_or("File changes")
    "webSearch" =>
      "Web search: " + @jsonx.json_text(fields, "query").unwrap_or("")
    "imageView" =>
      "Viewed image: " + @jsonx.json_text(fields, "path").unwrap_or("")
    "enteredReviewMode" | "exitedReviewMode" =>
      @jsonx.json_text(fields, "review").unwrap_or(self.kind)
    "contextCompaction" => "Compacted conversation context"
    _ => self.value.stringify()
  }
}

///|
test "Codex completed items replace streamed presentation state" {
  let started = CodexItem::decode({
    "id": "item-1",
    "type": "agentMessage",
    "text": "",
  }).unwrap()
  let turn : CodexTurn = {
    id: "turn-1",
    status: "inProgress",
    items: [started],
    error: None,
  }
  let streamed = turn.with_delta("item-1", "partial")
  assert_eq(streamed.items[0].text(), "partial")
  let completed = CodexItem::decode({
    "id": "item-1",
    "type": "agentMessage",
    "text": "final",
  }).unwrap()
  let settled = streamed.with_item(completed, completed=true)
  assert_eq(settled.items[0].text(), "final")
  assert_eq(settled.items[0].streamed, "")
}

///|
test "Codex user-input replies preserve exact question ids" {
  let request : CodexPendingRequest = {
    request_id: Json::number(7),
    method_: "item/tool/requestUserInput",
    params: {
      "questions": [
        {
          "id": "scope",
          "header": "Scope",
          "question": "Which scope?",
          "options": [{ "label": "Small", "description": "One package" }],
        },
      ],
    },
    answers: { "scope": "Small" },
  }
  assert_eq(
    request.response("accept"),
    Some({ "answers": { "scope": { "answers": ["Small"] } } }),
  )
}

///|
test "Codex account snapshots settle browser login state" {
  let state = {
    ..State(),
    login_id: Some("login-1"),
    auth_url: Some("https://example.invalid/login"),
  }
  let settled = state.with_account({
    "account": { "type": "chatgpt", "planType": "pro" },
    "requiresOpenaiAuth": true,
  })
  assert_eq(settled.login_id, None)
  assert_eq(settled.auth_url, None)
  assert_true(settled.account is CodexSignedIn(..))
}

///|
test "Codex archive notification closes the active thread" {
  let state = State().with_thread_reply({
    "thread": { "id": "thread-1", "turns": [] },
  })
  let settled = state.with_notification("thread/archived", {
    "threadId": "thread-1",
  })
  assert_true(settled.active is None)
  assert_eq(settled.threads.length(), 0)
}

///|
test "Codex thread replies are visible before catalog refresh" {
  let state = State().with_thread_reply({
    "thread": {
      "id": "thread-1",
      "cwd": "/project",
      "preview": "Smoke test",
      "turns": [],
    },
  })
  assert_eq(state.threads.length(), 1)
  assert_eq(state.threads[0].id, "thread-1")
  assert_eq(state.threads[0].title, "Smoke test")
  let refreshed = state.with_threads({ "data": [] })
  assert_eq(refreshed.threads.length(), 1)
  assert_eq(refreshed.threads[0].id, "thread-1")
}
