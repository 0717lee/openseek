// The native endpoint catalog behind both Desktop transports. Each entry
// pairs one typed command descriptor with its typed operation once; Proton
// binds the captured types directly, while remote JSON-RPC invokes the JSON
// closure retained by the same endpoint.

///|
/// Everything the methods operate on: the app-lifetime engine actor and its
/// request-side manager (one serve process per conversation), the host-op
/// state (LSP pool and updates), and the notification hub. One per host
/// process; each transport connection supplies its own `HostConnection` when
/// dispatching filesystem watch methods.
struct ApiState {
  // One Codex app-server process for this Desktop process. It is independent
  // of the OpenSeek engine actor and owns Codex account/thread state through
  // Codex's own data directory.
  codex : @codex.Actor
  // App-server returns each thread cwd but not its owning local project. Keep
  // Git's worktree relationship beside the Codex actor and reuse it across
  // list/read/start replies instead of making the browser infer path names.
  codex_projects : @codex.ProjectCatalog
  engine : @engine.EngineActor
  manager : @engine.EngineManager
  host : @host.HostState
  hub : Hub
  // The host's relay sign-in state, shared with the relay actor.
  auth : @auth.AuthStore
  // Installed package version read from Proton's generated package manifest.
  app_version : String
  // Called for every finished run, alongside the notification fan-out — the
  // desktop posts its system notification here.
  on_finished : ((@protocol.FinishedPayload) -> Unit)?
}

///|
/// The one filesystem authority extracted from a successful app-server
/// thread reply. It is never decoded from a Files or Terminal request: only
/// the native Codex actor's reply can establish this exact thread/cwd pair.
priv struct CodexWorkspaceBinding {
  session : String
  workspace : String?
}

///|
fn CodexWorkspaceBinding::decode_reply(value : Json) -> CodexWorkspaceBinding? {
  guard value is Object(fields) &&
    fields.get("thread") is Some(Object(thread)) &&
    thread.get("id") is Some(String(session)) else {
    return None
  }
  let workspace = match thread.get("cwd") {
    Some(String(cwd)) => Some(cwd)
    _ => None
  }
  Some({ session, workspace })
}

///|
/// Apply the app-server reply before it reaches the page, so a Files or
/// Terminal request caused by that render can resolve the cwd immediately.
async fn CodexWorkspaceBinding::authorize(self : CodexWorkspaceBinding) -> Unit {
  match self.workspace {
    Some(workspace) if !workspace.trim().is_empty() =>
      @engine.authorize_host_workspace(self.session, workspace)
    _ => @engine.revoke_host_workspace(self.session)
  }
}

///|
/// `engine` is the engine executable; `executable` is the host's own
/// binary, which self-update uses to locate the running .app bundle (absent
/// or non-bundle layouts only lose the in-app install, never the
/// announcement).
pub fn ApiState::new(
  engine~ : String,
  codex? : String = "codex",
  runtime_dir? : @pathx.Path,
  executable? : String,
  auth? : @auth.AuthStore,
  app_version? : String = "development",
  on_finished? : (@protocol.FinishedPayload) -> Unit,
) -> ApiState {
  let engine_actor = @engine.new_engine_actor(engine, runtime_dir?)
  {
    codex: Actor(codex),
    codex_projects: ProjectCatalog(),
    engine: engine_actor,
    manager: engine_actor.manager(),
    host: @host.new_host_state(engine, runtime_dir?, executable?, app_version~),
    hub: Hub::new(),
    auth: match auth {
      Some(store) => store
      None => @auth.AuthStore::empty(app_version~)
    },
    app_version,
    on_finished,
  }
}

///|
/// The app-lifetime owner of the Codex app-server child process.
pub fn ApiState::codex_actor(self : ApiState) -> @codex.Actor {
  self.codex
}

///|
/// The app-lifetime engine actor. Its `run` task owns all serve processes and
/// per-session follower children.
pub fn ApiState::engine_actor(self : ApiState) -> @engine.EngineActor {
  self.engine
}

///|
/// The sign-in store used by the relay actor running beside this dispatcher.
pub fn ApiState::auth_store(self : ApiState) -> @auth.AuthStore {
  self.auth
}

///|
/// The engine event sink: fan out to every subscriber, and hand finished
/// runs to the notification hook.
pub fn ApiState::sink(self : ApiState) -> @engine.EventSink {
  self.hub.sink(on_finished?=self.on_finished)
}

///|
/// Register a notification subscriber: a bounded queue the hub pushes every
/// notification into. The caller drains it with `get` and MUST `unsubscribe`
/// when done (a defer next to the subscribe). A subscriber that stops
/// draining is kicked by the hub: its queue is closed, which ends the
/// drain loop.
pub fn ApiState::subscribe(
  self : ApiState,
) -> @async.Queue[@protocol.Notification] {
  self.hub.subscribe()
}

///|
pub fn ApiState::unsubscribe(
  self : ApiState,
  queue : @async.Queue[@protocol.Notification],
) -> Unit {
  self.hub.unsubscribe(queue)
}

///|
/// Publish one notification to every subscriber — shared host pumps such as
/// `lsp.diagnostics` go through here. Connection-owned `fs.changed` events
/// bypass the hub and return only to their owning connection.
pub fn ApiState::publish(
  self : ApiState,
  notification : @protocol.Notification,
) -> Unit {
  self.hub.publish(notification)
}

///|
/// The host-op state, for the pumps spawned beside the dispatcher.
pub fn ApiState::host_state(self : ApiState) -> @host.HostState {
  self.host
}

///|
/// The request-side engine coordination handle.
pub fn ApiState::manager(self : ApiState) -> @engine.EngineManager {
  self.manager
}

///|
/// Device-native Scratch base for transports that publish their own initial
/// `agent.connected` notification outside the engine event pump.
pub async fn scratch_root() -> String {
  @engine.scratch_root()
}

///|
/// The commands shared by the embedded page and remote WebSocket. A generic
/// Endpoint constructor checks each payload/reply pair, then erases those
/// types only inside the two transport closures it creates.
pub fn endpoints(
  state : ApiState,
  connection : @host.HostConnection,
) -> Array[@endpoint.Endpoint] {
  let endpoints = [
    @endpoint.Endpoint::remote_sync(@commands.codex_status, _ => {
      state.codex.status()
    }),
    @endpoint.Endpoint::remote(@commands.codex_server_request_list, async fn(
      _,
    ) {
      state.codex.requests()
    }),
    @endpoint.Endpoint::remote(@commands.codex_server_request_respond, async fn(
      params,
    ) {
      let payload : CodexResponsePayload = @json.from_json(params) catch {
        _ => raise @host.PayloadError("malformed Codex response payload")
      }
      state.codex.respond(request_id=payload.request_id, result=payload.result)
    }),
    @endpoint.Endpoint::remote(@commands.codex_file_search, async fn(params) {
      let payload : CodexFileSearchPayload = @json.from_json(params) catch {
        _ => raise @host.PayloadError("malformed Codex file search payload")
      }
      state.codex_file_search(payload)
    }),
    state.codex_endpoint(@commands.codex_account_read),
    state.codex_endpoint(@commands.codex_account_login_start),
    state.codex_endpoint(@commands.codex_account_login_cancel),
    state.codex_endpoint(@commands.codex_account_logout),
    state.codex_endpoint(@commands.codex_model_list),
    state.codex_endpoint(@commands.codex_thread_start),
    state.codex_endpoint(@commands.codex_thread_resume),
    state.codex_endpoint(@commands.codex_thread_read),
    @endpoint.Endpoint::remote(@commands.codex_thread_history_read, async fn(
      params,
    ) {
      state.codex_thread_history(params)
    }),
    @endpoint.Endpoint::remote(@commands.codex_thread_activity_read, async fn(
      params,
    ) {
      state.codex_thread_activity(params)
    }),
    state.codex_endpoint(@commands.codex_thread_list),
    state.codex_endpoint(@commands.codex_thread_archive),
    state.codex_endpoint(@commands.codex_thread_unarchive),
    state.codex_endpoint(@commands.codex_thread_compact),
    state.codex_endpoint(@commands.codex_review_start),
    state.codex_endpoint(@commands.codex_turn_start),
    state.codex_endpoint(@commands.codex_turn_steer),
    state.codex_endpoint(@commands.codex_turn_interrupt),
    @endpoint.Endpoint::remote(@commands.agent_start, async fn(payload) {
      @engine.start_run(state.sink(), state.manager, payload)
    }),
    @endpoint.Endpoint::remote(@commands.agent_cancel, async fn(payload) {
      @engine.cancel_run(state.manager, payload)
    }),
    @endpoint.Endpoint::remote(@commands.agent_steer, async fn(payload) {
      @engine.steer_run(state.manager, payload)
    }),
    @endpoint.Endpoint::remote(@commands.agent_compact, async fn(payload) {
      @engine.compact_run(state.manager, payload)
    }),
    @endpoint.Endpoint::remote(@commands.agent_goal, async fn(payload) {
      @engine.goal_run(state.manager, payload)
    }),
    @endpoint.Endpoint::remote_sync(@commands.agent_runs, payload => {
      state.hub.runs(known?=payload.known)
    }),
    @endpoint.Endpoint::remote(@commands.session_list, async fn(_) {
      @engine.list_sessions(state.manager)
    }),
    @endpoint.Endpoint::remote(@commands.session_load, async fn(payload) {
      @engine.load_session(state.manager, payload)
    }),
    @endpoint.Endpoint::remote(@commands.session_load_archived, async fn(
      payload,
    ) {
      @engine.load_archived_session(state.manager, payload)
    }),
    @endpoint.Endpoint::remote(@commands.session_list_archived, async fn(_) {
      @engine.archived_sessions(state.manager, session => {
        publish_session_changed(state, "archived", session)
      })
    }),
    @endpoint.Endpoint::remote(@commands.session_archive, async fn(payload) {
      let session = payload.canonical_session()
      // The callback runs inside the rename's cancellation shield. Every
      // other client learns the canonical id before any cancellable list
      // reply, so a cancelled requester cannot suppress invalidation. The
      // worktree callback publishes the retained placement with
      // `present: false` before the archived identity becomes visible.
      @engine.archive_session(
        state.manager,
        session,
        moved => publish_session_changed(state, "archived", moved),
        force=payload.force == Some(true),
        on_worktree_changed=(workspace, worktrees) => {
          publish_worktree_changed(state, workspace, worktrees)
        },
      )
    }),
    @endpoint.Endpoint::remote(@commands.session_unarchive, async fn(payload) {
      let session = payload.canonical_session()
      @engine.unarchive_session(state.manager, session, moved => {
        publish_session_changed(state, "unarchived", moved)
      })
    }),
    @endpoint.Endpoint::remote(@commands.settings_get, async fn(_) {
      @engine.settings_status(state.manager)
    }),
    @endpoint.Endpoint::remote_sync(@commands.app_info, _ => {
      version: state.app_version,
    }),
    @endpoint.Endpoint::remote(@commands.settings_set, async fn(payload) {
      // The store commit and its broadcast are one finite cancellation-
      // shielded linearization point. `update_settings` invokes the callback
      // while its manager-owned lock is still held, preserving revision order
      // across concurrent clients even if the requester disconnects.
      @async.protect_from_cancel(() => {
        let status = @engine.update_settings(
          state.manager,
          payload.to_patch(),
          legacy_migration=payload.legacy_migration == Some(true),
          on_committed=fn(status) {
            // Every client renders these settings; clients that did not ask
            // must learn about the committed revision too.
            state.hub.publish(SettingsChanged(status))
          },
        )
        // Credentials belong to the server that issued them. Clear stale
        // credentials before this request can complete or be cancelled.
        sign_out_after_server_switch(state)
        status
      })
    }),
    @endpoint.Endpoint::remote(@commands.workspace_list, async fn(_) {
      @engine.list_workspaces()
    }),
    @endpoint.Endpoint::remote(@commands.workspace_add, async fn(payload) {
      // A refusal travels inside the reply: the local bridge would flatten
      // a raised error to "op ext:openseek/workspace.add failed".
      @engine.attach_workspace(payload.path, workspaces => {
        state.hub.publish(WorkspaceChanged({ workspaces, }))
      }) catch {
        error if @async.is_being_cancelled() => raise error
        @engine.EngineError(message) => WorkspaceError(message)
        error => raise error
      }
    }),
    @endpoint.Endpoint::remote(@commands.workspace_remove, async fn(payload) {
      @engine.detach_workspace(state.manager, payload.path, workspaces => {
        state.hub.publish(WorkspaceChanged({ workspaces, }))
      }) catch {
        error if @async.is_being_cancelled() => raise error
        @engine.EngineError(message) => WorkspaceError(message)
        error => raise error
      }
    }),
    @endpoint.Endpoint::remote(@commands.workspace_settings_get, async fn(
      payload,
    ) {
      @engine.workspace_settings(payload.workspace)
    }),
    @endpoint.Endpoint::remote(@commands.workspace_settings_set, async fn(
      payload,
    ) {
      // The store commit and its broadcast are one shielded linearization
      // point inside the engine, the `workspace.add` pattern.
      let worktree_mode = payload.worktree_mode
      let checkout_submodules = payload.checkout_submodules
      let submodule_checkout_timeout_seconds = payload.submodule_checkout_timeout_seconds
      @engine.update_workspace_settings(
        payload.workspace,
        settings => state.hub.publish(WorkspaceSettingsChanged(settings)),
        worktree_mode?,
        checkout_submodules?,
        submodule_checkout_timeout_seconds?,
      )
    }),
    @endpoint.Endpoint::remote(@commands.worktree_list, async fn(payload) {
      @engine.list_worktrees(payload.workspace)
    }),
    @endpoint.Endpoint::remote(@commands.worktree_create, async fn(payload) {
      let reply = @engine.create_worktree(
        state.manager,
        payload.workspace,
        payload.session,
        worktrees => {
          publish_worktree_changed(state, payload.workspace, worktrees)
        },
      ) catch {
        error if @async.is_being_cancelled() => raise error
        @engine.EngineError(message) => return WorktreeCreateError(message)
        error => raise error
      }
      WorktreeCreatedReply(reply)
    }),
    @endpoint.Endpoint::remote(@commands.worktree_remove, async fn(payload) {
      @engine.remove_worktree(
        state.manager,
        payload.workspace,
        payload.name,
        payload.force == Some(true),
        worktrees => {
          publish_worktree_changed(state, payload.workspace, worktrees)
        },
      )
    }),
    @endpoint.Endpoint::remote(@commands.auth_status, async fn(_) {
      auth_status(state)
    }),
    @endpoint.Endpoint::remote(@commands.auth_connect, async fn(_) {
      auth_connect(state)
    }),
    @endpoint.Endpoint::remote(@commands.auth_disconnect, async fn(_) {
      auth_disconnect(state)
    }),
    @endpoint.Endpoint::remote(@commands.auth_cancel, async fn(_) {
      auth_cancel(state)
    }),
  ]
  for
    endpoint in @host.endpoints(state.host, connection, () => {
      state.publish(SkillsChanged)
    }) {
    endpoints.push(endpoint)
  }
  endpoints
}

///|
/// Pair one reviewed Codex command identity with the app-server forwarding
/// method. The command name is the Desktop method name used by
/// `codex_request`; no second catalog can drift from the registered endpoint.
fn ApiState::codex_endpoint(
  self : ApiState,
  command : @commands.Command[Json, Json],
) -> @endpoint.Endpoint {
  let desktop_method = command.name()
  @endpoint.Endpoint::remote(command, async fn(params) {
    self.codex_request(desktop_method, params)
  })
}

///|
test "remote endpoint catalog has one entry per command name" {
  let state = ApiState::new(engine="unused")
  let connection = @host.HostConnection::new()
  let names : Array[String] = []
  for endpoint in endpoints(state, connection) {
    let name = endpoint.name()
    if names.contains(name) {
      fail("duplicate endpoint: " + name)
    }
    names.push(name)
  }
  assert_eq(names.length(), 78)
  assert_true(names.contains("codex.file.search"))
  assert_true(names.contains("codex.review.start"))
  assert_true(names.contains("codex.thread.history.read"))
  assert_true(names.contains("codex.thread.list"))
  assert_true(names.contains("agent.start"))
  assert_true(names.contains("agent.goal"))
  assert_true(names.contains("session.load_archived"))
  assert_true(names.contains("workspace.settings_get"))
  assert_true(names.contains("workspace.settings_set"))
  assert_true(names.contains("app.info"))
  assert_true(names.contains("git.changes"))
  assert_true(names.contains("git.pull_request"))
  assert_true(names.contains("git.original_file"))
  assert_true(names.contains("terminal.close"))
  assert_true(names.contains("fs.search_files"))
  assert_true(names.contains("fs.cancel_search_files"))
  assert_true(names.contains("fs.clear_file_search_cache"))
  assert_true(names.contains("moonide.references"))
  assert_false(names.contains("host.connect"))
  assert_false(names.contains("shell.open_external"))
}

///|
/// Return one complete read-only thread snapshot across both app-server
/// history modes. Metadata says which store owns the turns, avoiding an
/// expected JSON-RPC failure on every paginated task. Legacy threads then take
/// the stable inline read; a task awaiting its first user message legitimately
/// has only the summary and is returned as an empty conversation. Paginated
/// threads load every page in ascending order with full items and rebuild the
/// same `{ thread }` shape the browser decodes.
async fn ApiState::codex_thread_history(self : ApiState, params : Json) -> Json {
  guard params is Object(fields) &&
    fields.get("threadId") is Some(String(thread_id)) else {
    raise @host.PayloadError("malformed Codex thread history payload")
  }
  let metadata = self.codex_request("codex.thread.read", {
    "threadId": thread_id,
    "includeTurns": false,
  })
  guard metadata is Object(reply_fields) &&
    reply_fields.get("thread") is Some(Object(thread_fields)) else {
    raise @host.PayloadError("malformed Codex thread metadata reply")
  }
  let paginated = thread_fields.get("historyMode") is Some(String("paginated"))
  if !paginated {
    return try
      self.codex_request("codex.thread.read", {
        "threadId": thread_id,
        "includeTurns": true,
      })
    catch {
      @codex.JsonRpc(..) as error if error.is_unmaterialized_thread_history() =>
        // The summary already identifies the task and its cwd. The frontend
        // decodes an omitted `turns` field as an empty transcript, matching
        // the task's real state before its first prompt is sent.
        metadata
      error => raise error
    } noraise {
      value => value
    }
  }
  let turns : Array[Json] = []
  let mut cursor : String? = None
  for ;; {
    let page_fields : Map[String, Json] = {
      "threadId": Json::string(thread_id),
      "limit": Json::number(100.0),
      "sortDirection": Json::string("asc"),
      "itemsView": Json::string("full"),
    }
    if cursor is Some(cursor) {
      page_fields["cursor"] = Json::string(cursor)
    }
    let page = self.codex.call(
      method_="thread/turns/list",
      params=Json::object(page_fields),
    )
    guard page is Object(page_fields) &&
      page_fields.get("data") is Some(Array(data)) else {
      raise @host.PayloadError("malformed Codex turn history page")
    }
    for turn in data {
      turns.push(turn)
    }
    match page_fields.get("nextCursor") {
      Some(String(next)) if !next.is_empty() => cursor = Some(next)
      _ => break
    }
  }
  let thread : Map[String, Json] = Map([])
  for key, value in thread_fields {
    thread[key] = value
  }
  thread["turns"] = Json::array(turns)
  let reply : Map[String, Json] = Map([])
  for key, value in reply_fields {
    reply[key] = value
  }
  reply["thread"] = Json::object(thread)
  Json::object(reply)
}

///|
/// Return only the newest turn for live status reconciliation. Unlike
/// `thread.status`, which is scoped to one app-server process, persisted turn
/// timestamps are visible across Codex clients. `itemsView=summary` keeps this
/// two-second poll bounded even for a multi-day legacy conversation.
async fn ApiState::codex_thread_activity(
  self : ApiState,
  params : Json,
) -> Json {
  guard params is Object(fields) &&
    fields.get("threadId") is Some(String(thread_id)) else {
    raise @host.PayloadError("malformed Codex thread activity payload")
  }
  let page = try
    self.codex.call(method_="thread/turns/list", params={
      "threadId": thread_id,
      "limit": 1,
      "sortDirection": "desc",
      "itemsView": "summary",
    })
  catch {
    @codex.JsonRpc(..) as error if error.is_unmaterialized_thread_activity() =>
      Json::null()
    error => raise error
  } noraise {
    value => value
  }
  if page is Null {
    return { "threadId": thread_id, "turn": Json::null() }
  }
  guard page is Object(page_fields) &&
    page_fields.get("data") is Some(Array(turns)) else {
    raise @host.PayloadError("malformed Codex thread activity reply")
  }
  { "threadId": thread_id, "turn": turns.get(0).unwrap_or(Json::null()) }
}

///|
/// Search only the exact cwd authorized by an app-server thread reply. The
/// public method does not accept app-server `roots` directly, so a remote page
/// cannot use Codex's file index as an arbitrary filesystem search.
async fn ApiState::codex_file_search(
  self : ApiState,
  payload : CodexFileSearchPayload,
) -> Json {
  guard @engine.resolve_in_workspace(
      payload.thread_id,
      "",
      workspace=payload.cwd,
    )
    is Some(root) else {
    raise @host.HostError("Codex workspace is not authorized")
  }
  self.codex.call(method_="fuzzyFileSearch", params={
    "query": payload.query,
    "roots": [Json::string(root.to_string())],
  })
}

///|
/// Map the Desktop's explicit Codex catalog onto the stable app-server method
/// names. There is deliberately no arbitrary method proxy: a relay browser can
/// invoke only the same reviewed surface as the local Proton page.
async fn ApiState::codex_request(
  self : ApiState,
  desktop_method : String,
  params : Json,
) -> Json {
  let app_server_method = match desktop_method {
    "codex.account.read" => "account/read"
    "codex.account.login.start" => "account/login/start"
    "codex.account.login.cancel" => "account/login/cancel"
    "codex.account.logout" => "account/logout"
    "codex.model.list" => "model/list"
    "codex.thread.start" => "thread/start"
    "codex.thread.resume" => "thread/resume"
    "codex.thread.read" => "thread/read"
    "codex.thread.list" => "thread/list"
    "codex.thread.archive" => "thread/archive"
    "codex.thread.unarchive" => "thread/unarchive"
    "codex.thread.compact" => "thread/compact/start"
    "codex.review.start" => "review/start"
    "codex.turn.start" => "turn/start"
    "codex.turn.steer" => "turn/steer"
    "codex.turn.interrupt" => "turn/interrupt"
    _ => raise @host.PayloadError("unknown Codex method: " + desktop_method)
  }
  let scoped_params = match (desktop_method, params) {
    // Custom app-server clients currently persist ordinary interactive
    // threads as `vscode`, while older/newer records may use `appServer`.
    // Preserve the caller's source filter (or Codex's interactive default)
    // instead of hiding threads that OpenSeek itself just created.
    ("codex.thread.list", Object(fields)) => {
      let scoped : Map[String, Json] = Map([])
      for key, value in fields {
        scoped[key] = value
      }
      // JSONL scan-and-repair can exceed the Proton request deadline on a
      // long-lived Codex home. The Desktop catalog is an interactive state
      // query, so read the app-server state database without that repair pass.
      scoped["useStateDbOnly"] = true
      Json::object(scoped)
    }
    ("codex.thread.list", _) => { "useStateDbOnly": true }
    // Tag new threads with this integration for Codex-side metrics. Preserve
    // every user-selected model, cwd, sandbox, and approval policy field.
    ("codex.thread.start", Object(fields)) => {
      let scoped : Map[String, Json] = Map([])
      for key, value in fields {
        scoped[key] = value
      }
      scoped["serviceName"] = "openseek_desktop"
      Json::object(scoped)
    }
    ("codex.thread.start", _) => { "serviceName": "openseek_desktop" }
    _ => params
  }
  let reply = try
    self.codex.call(method_=app_server_method, params=scoped_params)
  catch {
    @codex.JsonRpc(..) as error if desktop_method == "codex.thread.resume" &&
      error.is_active_writer() =>
      // A stored task remains readable while another Codex client owns its
      // writer. Return a safe state instead of leaking arbitrary RPC details
      // through Proton's browser boundary.
      Json::object({ "status": Json::string("activeWriter") })
    error => raise error
  } noraise {
    value => value
  }
  if desktop_method == "codex.thread.resume" &&
    reply is Object(fields) &&
    fields.get("status") is Some(String("activeWriter")) {
    return reply
  }
  let reply = match desktop_method {
    "codex.thread.start"
    | "codex.thread.resume"
    | "codex.thread.read"
    | "codex.thread.list" => self.codex_projects.annotate(reply)
    _ => reply
  }
  match desktop_method {
    "codex.thread.start" | "codex.thread.resume" | "codex.thread.read" =>
      if CodexWorkspaceBinding::decode_reply(reply) is Some(binding) {
        binding.authorize()
      }
    "codex.thread.archive" =>
      if params is Object(fields) &&
        fields.get("threadId") is Some(String(session)) {
        @engine.revoke_host_workspace(session)
      }
    _ => ()
  }
  reply
}

///|
test "Codex workspace bindings decode only authoritative thread replies" {
  let binding = CodexWorkspaceBinding::decode_reply({
    "thread": { "id": "codex-thread-1", "cwd": "/work/project", "turns": [] },
  })
  assert_true(
    binding
    is Some({ session: "codex-thread-1", workspace: Some("/work/project") }),
  )
  assert_true(CodexWorkspaceBinding::decode_reply({ "thread": {} }) is None)
  assert_true(CodexWorkspaceBinding::decode_reply({}) is None)
}

///|
/// Tell every client a conversation moved between the live and archived
/// stores, so the ones that did not ask re-read both lists and drop live
/// state for the moved record.
fn publish_session_changed(
  state : ApiState,
  change : String,
  session : String,
) -> Unit {
  state.hub.publish(SessionChanged({ change, session }))
}

///|
/// Tell every client a workspace's worktree list changed, so sidebars
/// re-join their name chips and pickers refresh — the `workspace.changed`
/// pattern, keyed by the workspace the list belongs to.
fn publish_worktree_changed(
  state : ApiState,
  workspace : String,
  worktrees : Array[@protocol.WorktreeInfo],
) -> Unit {
  state.hub.publish(
    WorktreeChanged({ workspace: workspace.trim().to_owned(), worktrees }),
  )
}
