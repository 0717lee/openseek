// App-lifetime owner of one dsh Web process. Requests enter a bounded command
// queue; the two downlink WebSockets enter a separate bounded event queue so
// a stalled Desktop page cannot block dsh's event producers indefinitely.

///|
priv suberror DshError {
  RequestFailed(String, String)
  Unavailable(String)
} derive(Debug)

///|
impl Show for DshError with fn output(self, logger) {
  match self {
    RequestFailed(method_, detail) =>
      logger.write_string("dsh request \{method_} failed: \{detail}")
    Unavailable(message) => logger.write_string(message)
  }
}

///|
fn DshError::log(self : DshError) -> Unit {
  match self {
    RequestFailed(method_, detail) =>
      @xlog.error(category="dsh") <?
        { "event": "dsh_request_failed", "method": method_, "error": detail }
    Unavailable(message) =>
      @xlog.warn(category="dsh") <?
        { "event": "dsh_unavailable", "error": message }
  }
}

///|
priv enum ConnectionState {
  Starting
  Ready
  Unavailable(String)
}

///|
priv enum ActorInput {
  Call(
    String,
    Json,
    @async.Queue[Result[(Json, DshConnectionRevision), DshError]]
  )
  Respond(Json, @async.Queue[Result[(Json, Int), DshError]])
  ListInteractions(@async.Queue[Result[Json, DshError]])
}

///|
/// The socket generation and Workspace-removal revision at which one HTTP
/// request entered the actor. Together they prevent a list captured before a
/// host removal event from restoring the grants that event just revoked.
pub(all) struct DshConnectionRevision {
  connection : Int
  workspaces : Int
  sessions : Int
} derive(Debug, Eq)

///|
priv enum DshEvent {
  Frame(String, Json)
}

///|
priv enum ActorStep {
  Input(ActorInput)
  Event(DshEvent)
  Disconnected
}

///|
const ActorInputCapacity : Int = 256

///|
const DshEventCapacity : Int = 2048

///|
const DshDisconnectCapacity : Int = 1

///|
const ActorWakeCapacity : Int = 1

///|
/// The actor owns interaction membership for the whole Desktop lifetime. Its
/// generation orders a page-attach snapshot against live mux events, so a
/// slower old snapshot cannot remove a newer approval or question.
priv struct PendingInteractionRegistry {
  mut requests : Map[String, Json]
  mut generation : Int
}

///|
fn PendingInteractionRegistry::PendingInteractionRegistry() -> PendingInteractionRegistry {
  { requests: Map([]), generation: 0 }
}

///|
fn PendingInteractionRegistry::reset(self : PendingInteractionRegistry) -> Unit {
  self.requests = Map([])
  self.generation = self.generation + 1
}

///|
fn PendingInteractionRegistry::remove_rpc(
  self : PendingInteractionRegistry,
  rpc_id : String,
) -> Unit {
  guard self.requests.get(rpc_id) is Some(_) else { return }
  self.requests.remove(rpc_id)
  self.generation = self.generation + 1
}

///|
/// An accepted HTTP receipt is authoritative even if the independent mux
/// resolution event has not arrived yet. Remove only the request named by a
/// well-formed client response; rejected or malformed receipts remain pending.
fn PendingInteractionRegistry::remove_accepted_response(
  self : PendingInteractionRegistry,
  message : Json,
  receipt : Json,
) -> Unit {
  guard receipt is Object(receipt_fields) &&
    receipt_fields.get("accepted") is Some(True) &&
    message is Object(message_fields) &&
    @jsonx.json_text(message_fields, "rpcId") is Some(rpc_id) else {
    return
  }
  self.remove_rpc(rpc_id)
}

///|
fn PendingInteractionRegistry::remove_approval(
  self : PendingInteractionRegistry,
  approval_id : String,
) -> Unit {
  let matched : Array[String] = []
  for rpc_id, request in self.requests {
    guard request is Object(fields) &&
      fields.get("payload") is Some(Object(payload)) &&
      @jsonx.json_text(payload, "type") == Some("approval/requested") &&
      @jsonx.json_text(payload, "approvalId") == Some(approval_id) else {
      continue
    }
    matched.push(rpc_id)
  }
  for rpc_id in matched {
    self.remove_rpc(rpc_id)
  }
}

///|
fn PendingInteractionRegistry::observe(
  self : PendingInteractionRegistry,
  message : Json,
) -> Unit {
  guard message is Object(fields) &&
    @jsonx.json_text(fields, "rpcId") is Some(rpc_id) &&
    fields.get("payload") is Some(Object(payload)) &&
    @jsonx.json_text(payload, "type") is Some(type_) else {
    return
  }
  match type_ {
    "approval/requested" | "question/requested" => {
      self.requests[rpc_id] = message
      self.generation = self.generation + 1
    }
    "approval/resolved" =>
      if @jsonx.json_text(payload, "approvalId") is Some(approval_id) {
        self.remove_approval(approval_id)
      }
    "question/resolved" =>
      self.remove_rpc(
        @jsonx.json_text(payload, "questionRpcId").unwrap_or(rpc_id),
      )
    _ => ()
  }
}

///|
fn PendingInteractionRegistry::snapshot(
  self : PendingInteractionRegistry,
) -> Json {
  let data : Array[Json] = []
  for _, message in self.requests {
    data.push({
      "stream": "mux",
      "message": message,
      "generation": self.generation,
    })
  }
  { "data": data, "generation": self.generation }
}

///|
struct Actor {
  inputs : @async.Queue[ActorInput]
  wake : @async.Queue[Unit]
  mut state : ConnectionState
  // Every connection-state transition receives a process-lifetime revision.
  // Both status polls and notifications carry it, so renderer delivery order
  // cannot let an older poll roll back a newer notification.
  mut status_revision : Int
  mut generation : Int
  mut workspace_revision : Int
  // host/session-status events and session.list dispatches share this actor
  // clock. The captured request revision describes the exact HTTP baseline,
  // even when the renderer request waited in its ordered lane first.
  mut session_revision : Int
  mut next_rpc_id : Int
  interactions : PendingInteractionRegistry
}

///|
pub fn Actor::Actor() -> Actor {
  {
    inputs: Queue(kind=Blocking(ActorInputCapacity)),
    wake: Queue(kind=Blocking(ActorWakeCapacity)),
    state: Starting,
    status_revision: 0,
    generation: 0,
    workspace_revision: 0,
    session_revision: 0,
    next_rpc_id: 0,
    interactions: PendingInteractionRegistry(),
  }
}

///|
fn Actor::signal(self : Actor) -> Unit {
  (self.wake.try_put(()) catch { _ => false }) |> ignore
}

///|
pub fn Actor::status(self : Actor) -> Json {
  match self.state {
    Starting => { "status": "starting", "revision": self.status_revision }
    Ready => { "status": "ready", "revision": self.status_revision }
    Unavailable(message) =>
      {
        "status": "unavailable",
        "message": message,
        "revision": self.status_revision,
      }
  }
}

///|
/// Move the actor to one observable connection state and advance the revision
/// before either a status poll or notification can read it.
fn Actor::set_connection_state(self : Actor, state : ConnectionState) -> Unit {
  self.state = state
  self.status_revision += 1
}

///|
/// Queue one allowlisted ApiProxy request. The API package owns the allowlist;
/// this process owner only serializes the physical carrier envelope. The reply
/// includes the connection generation that actually dispatched the HTTP call,
/// which may differ from the generation where the input was first queued.
pub async fn Actor::call(
  self : Actor,
  method_~ : String,
  payload~ : Json,
) -> (Json, DshConnectionRevision) {
  let reply : @async.Queue[Result[(Json, DshConnectionRevision), DshError]] = Queue(
    kind=Blocking(1),
  )
  self.inputs.put(Call(method_, payload, reply))
  self.signal()
  match reply.get() {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
/// Queue one complete client-response for a pending dsh approval or question.
/// The returned registry generation is captured after an accepted response
/// removes its interaction, so the page can reject an older in-flight snapshot.
pub async fn Actor::respond(self : Actor, message : Json) -> (Json, Int) {
  let reply : @async.Queue[Result[(Json, Int), DshError]] = Queue(
    kind=Blocking(1),
  )
  self.inputs.put(Respond(message, reply))
  self.signal()
  match reply.get() {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
/// List the approval and question requests still owned by the current dsh
/// connection. A newly attached page reads this after status so it can recover
/// interactions emitted before its Proton event subscription existed.
pub async fn Actor::interactions(self : Actor) -> Json {
  let reply : @async.Queue[Result[Json, DshError]] = Queue(kind=Blocking(1))
  self.inputs.put(ListInteractions(reply))
  self.signal()
  match reply.get() {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
/// Own dsh for the Desktop lifetime. A failed executable or disconnected API
/// stays quiet until the next command asks for one reconnect attempt.
pub async fn Actor::run(
  self : Actor,
  emit : (String, Json) -> Unit,
  invalidate_workspaces~ : async (Int, Int) -> Unit,
  revoke_workspaces~ : async (Int) -> Unit,
  release_worktree~ : async (String) -> Unit,
) -> Unit {
  let mut first = true
  for ;; {
    let pending = if first {
      first = false
      None
    } else {
      Some(self.inputs.get())
    }
    @async.with_task_group(group => {
      self.run_connection(
        group,
        pending,
        emit,
        invalidate_workspaces~,
        revoke_workspaces~,
        release_worktree~,
      )
    })
  }
}

///|
async fn[G] Actor::run_connection(
  self : Actor,
  group : @async.TaskGroup[G],
  pending : ActorInput?,
  emit : (String, Json) -> Unit,
  invalidate_workspaces~ : async (Int, Int) -> Unit,
  revoke_workspaces~ : async (Int) -> Unit,
  release_worktree~ : async (String) -> Unit,
) -> Unit {
  self.set_connection_state(Starting)
  self.generation += 1
  self.workspace_revision = 0
  let generation = self.generation
  // Requests from an older WebSocket generation cannot be answered on this
  // connection. The new mux baseline will repopulate still-pending requests.
  self.interactions.reset()
  emit("dsh.status_changed", self.status())
  let events : @async.Queue[DshEvent] = Queue(kind=Blocking(DshEventCapacity))
  // Disconnects cannot share `events`: queue saturation is itself one reason
  // a pump exits, and a sentinel written back into that full queue could vanish.
  let disconnects : @async.Queue[Unit] = Queue(
    kind=Blocking(DshDisconnectCapacity),
  )
  let connection = Connection::connect(group) catch {
    error if @async.is_being_cancelled() => raise error
    error => {
      // Connection startup errors already distinguish executable lookup,
      // readiness timeout, and dsh's own stderr. Preserve that explanation
      // for the frontend instead of misreporting every failure as PATH.
      let message = "\{error}"
      self.set_connection_state(Unavailable(message))
      emit("dsh.status_changed", self.status())
      if pending is Some(input) {
        input.reject(Unavailable(message))
      }
      return
    }
  }
  let receive = (stream : String, value : Json) => {
    let accepted = events.try_put(Frame(stream, value)) catch { _ => false }
    self.signal()
    accepted
  }
  for stream in ["mux", "host"] {
    group.spawn_bg(allow_failure=true, () => {
      connection.pump(stream, receive) catch {
        error if @async.is_being_cancelled() => raise error
        error =>
          @xlog.warn(category="dsh") <?
            {
              "event": "dsh_websocket_closed",
              "stream": stream,
              "error": "\{error}",
            }
      }
      // One signal is enough to tear down both pumps. A second pump may find
      // this one-slot queue full, which means the disconnect is already owned.
      (disconnects.try_put(()) catch { _ => false }) |> ignore
      self.signal()
    })
  }
  self.set_connection_state(Ready)
  emit("dsh.status_changed", self.status())
  if pending is Some(input) {
    connection.dispatch_input(group, self, generation, input)
  }
  for ;; {
    let next = self.next_step(events, disconnects) catch {
      error if @async.is_being_cancelled() => raise error
      _ => break
    }
    match next {
      Input(input) => connection.dispatch_input(group, self, generation, input)
      Event(Frame(stream, message)) =>
        self.publish_frame(
          stream,
          message,
          emit,
          invalidate_workspaces~,
          release_worktree~,
        )
      Disconnected => break
    }
  }
  connection.shutdown()
  self.finish_disconnect(emit, revoke_workspaces~)
}

///|
/// Apply host-owned lifecycle effects before the renderer observes a frame.
/// A removed dsh conversation releases its Desktop worktree row without
/// deleting the checkout. A changed or removed Workspace immediately
/// invalidates the current generation's dsh grants; the following
/// workspace.list may restore only the memberships that remain.
async fn Actor::publish_frame(
  self : Actor,
  stream : String,
  message : Json,
  emit : (String, Json) -> Unit,
  invalidate_workspaces~ : async (Int, Int) -> Unit,
  release_worktree~ : async (String) -> Unit,
) -> Unit {
  if stream == "mux" {
    self.interactions.observe(message)
  }
  if stream == "host" &&
    message is Object(fields) &&
    fields.get("payload") is Some(Object(payload)) {
    match @jsonx.json_text(payload, "type") {
      Some("host/session-status") => self.session_revision += 1
      Some("host/session-removed") => {
        if @jsonx.json_text(payload, "sessionId") is Some(session_id) {
          release_worktree(session_id) catch {
            error if @async.is_being_cancelled() => raise error
            error =>
              // Registry cleanup is best-effort at this event boundary.
              // Losing the actor would also skip the removal event and later
              // grant revocation, leaving subsequent requests unconsumed.
              @xlog.error(category="dsh") <?
                {
                  "event": "dsh_worktree_release_failed",
                  "session_id": session_id,
                  "error": "\{error}",
                }
          }
        }
        self.workspace_revision += 1
        invalidate_workspaces(self.generation, self.workspace_revision)
      }
      Some("host/workspace-changed") | Some("host/workspace-removed") => {
        self.workspace_revision += 1
        invalidate_workspaces(self.generation, self.workspace_revision)
      }
      _ => ()
    }
  }
  emit("dsh.event", {
    "stream": stream,
    "message": message,
    "generation": self.interactions.generation,
    "sessionRevision": self.session_revision,
  })
}

///|
/// Leave one ready WebSocket generation only after its dsh-derived Workspace
/// grants are gone. The unavailable notification is deliberately last: once
/// the page observes it, Files and Terminal can no longer use the old rows.
async fn Actor::finish_disconnect(
  self : Actor,
  emit : (String, Json) -> Unit,
  revoke_workspaces~ : async (Int) -> Unit,
) -> Unit {
  self.set_connection_state(Unavailable("DeepSeek Harness disconnected"))
  revoke_workspaces(self.generation)
  emit("dsh.status_changed", self.status())
}

///|
async fn Actor::next_step(
  self : Actor,
  events : @async.Queue[DshEvent],
  disconnects : @async.Queue[Unit],
) -> ActorStep {
  for ;; {
    // Once either pump is gone, requests cannot rely on the complete dsh event
    // surface. Tear down promptly and let the next input reopen both streams.
    if (disconnects.try_get() catch { _ => None }) is Some(_) {
      return Disconnected
    }
    if (self.inputs.try_get() catch { _ => None }) is Some(input) {
      return Input(input)
    }
    let event = events.try_get() catch { _ => return Disconnected }
    if event is Some(event) {
      return Event(event)
    }
    self.wake.get()
  }
}

///|
fn ActorInput::reject(self : ActorInput, error : DshError) -> Unit {
  error.log()
  match self {
    Call(_, _, reply) =>
      (reply.try_put(Err(error)) catch { _ => false }) |> ignore
    Respond(_, reply) =>
      (reply.try_put(Err(error)) catch { _ => false }) |> ignore
    ListInteractions(reply) =>
      (reply.try_put(Err(error)) catch { _ => false }) |> ignore
  }
}

///|
fn[G] Connection::dispatch_input(
  self : Connection,
  group : @async.TaskGroup[G],
  actor : Actor,
  generation : Int,
  input : ActorInput,
) -> Unit {
  match input {
    Call(method_, payload, reply) => {
      actor.next_rpc_id += 1
      let rpc_id = "openseek-desktop-\{actor.next_rpc_id}"
      let revision : DshConnectionRevision = {
        connection: generation,
        workspaces: actor.workspace_revision,
        sessions: actor.session_revision,
      }
      group.spawn_bg(allow_failure=true, () => {
        let outcome : Result[(Json, DshConnectionRevision), DshError] = try
          self.request(method_~, rpc_id~, payload~)
        catch {
          error => {
            // A closed WebSocket ends this connection's task group. Complete
            // every in-flight caller even when that cancellation interrupts
            // its HTTP task; otherwise the page could wait forever on reply.
            let detail = if @async.is_being_cancelled() {
              "dsh connection closed"
            } else {
              "\{error}"
            }
            let failure = RequestFailed(method_, detail)
            failure.log()
            Err(failure)
          }
        } noraise {
          value => Ok((value, revision))
        }
        (reply.try_put(outcome) catch { _ => false }) |> ignore
      })
    }
    Respond(message, reply) =>
      group.spawn_bg(allow_failure=true, () => {
        let outcome : Result[(Json, Int), DshError] = try
          self.respond(message)
        catch {
          error => {
            let detail = if @async.is_being_cancelled() {
              "dsh connection closed"
            } else {
              "\{error}"
            }
            let failure = RequestFailed("respond", detail)
            failure.log()
            Err(failure)
          }
        } noraise {
          value => {
            // Publish removal before returning the accepted receipt so a page
            // attach cannot replay controls that dsh has already consumed.
            actor.interactions.remove_accepted_response(message, value)
            Ok((value, actor.interactions.generation))
          }
        }
        (reply.try_put(outcome) catch { _ => false }) |> ignore
      })
    ListInteractions(reply) =>
      (reply.try_put(Ok(actor.interactions.snapshot())) catch { _ => false })
      |> ignore
  }
}

///|
async test "dsh actor tracks pending interactions and consumes buffered commands" {
  let actor = Actor()
  actor.interactions.observe({
    "rpcId": "approval-rpc",
    "payload": {
      "type": "approval/requested",
      "sessionId": "session-1",
      "approvalId": "approval-1",
      "toolName": "write",
    },
  })
  @debug.assert_eq(actor.interactions.snapshot(), {
    "data": [
      {
        "stream": "mux",
        "message": {
          "rpcId": "approval-rpc",
          "payload": {
            "type": "approval/requested",
            "sessionId": "session-1",
            "approvalId": "approval-1",
            "toolName": "write",
          },
        },
        "generation": 1,
      },
    ],
    "generation": 1,
  })
  actor.interactions.observe({
    "rpcId": "resolved-rpc",
    "payload": {
      "type": "approval/resolved",
      "sessionId": "session-1",
      "approvalId": "approval-1",
      "outcome": "allowed-once",
    },
  })
  @debug.assert_eq(actor.interactions.snapshot(), {
    "data": [],
    "generation": 2,
  })
  let events : @async.Queue[DshEvent] = Queue(kind=Blocking(1))
  let disconnects : @async.Queue[Unit] = Queue(kind=Blocking(1))
  let reply : @async.Queue[Result[(Json, DshConnectionRevision), DshError]] = Queue(
    kind=Blocking(1),
  )
  actor.inputs.put(Call("session.list", {}, reply))
  let step = actor.next_step(events, disconnects)
  assert_true(step is Input(Call("session.list", _, _)))
  // A separate lane remains writable even when event backpressure is the
  // reason a pump exits, and disconnect wins over the queued event.
  events.put(Frame("mux", {}))
  disconnects.put(())
  assert_true(actor.next_step(events, disconnects) is Disconnected)
}

///|
test "dsh actor removes only interactions with accepted response receipts" {
  let interactions = PendingInteractionRegistry()
  let request : Json = {
    "rpcId": "question-rpc",
    "payload": {
      "type": "question/requested",
      "sessionId": "session-1",
      "questions": [],
    },
  }
  interactions.observe(request)
  interactions.remove_accepted_response(request, { "accepted": false })
  @debug.assert_eq(interactions.snapshot(), {
    "data": [{ "stream": "mux", "message": request, "generation": 1 }],
    "generation": 1,
  })
  interactions.remove_accepted_response({}, { "accepted": true })
  assert_eq(interactions.generation, 1)
  interactions.remove_accepted_response(request, { "accepted": true })
  @debug.assert_eq(interactions.snapshot(), { "data": [], "generation": 2 })
}

///|
async test "dsh actor releases a removed session before publishing its event" {
  let actor = Actor()
  actor.generation = 4
  let order : Array[String] = []
  let released : @async.Queue[String] = Queue(kind=Blocking(1))
  let invalidated : @async.Queue[(Int, Int)] = Queue(kind=Blocking(1))
  actor.publish_frame(
    "host",
    {
      "rpcId": "host-1",
      "payload": { "type": "host/session-removed", "sessionId": "session-1" },
    },
    (method_, _) => order.push(method_),
    invalidate_workspaces=async fn(generation, revision) {
      invalidated.put((generation, revision))
      order.push("invalidated")
    },
    release_worktree=async fn(session_id) {
      released.put(session_id)
      order.push("released:" + session_id)
    },
  )
  assert_eq(released.get(), "session-1")
  assert_eq(invalidated.get(), (4, 1))
  assert_eq(order, ["released:session-1", "invalidated", "dsh.event"])
}

///|
async test "dsh actor revisions session status before publishing it" {
  let actor = Actor()
  actor.session_revision = 6
  let published : Array[Json] = []
  actor.publish_frame(
    "host",
    {
      "rpcId": "status-1",
      "payload": {
        "type": "host/session-status",
        "sessionId": "session-1",
        "running": true,
      },
    },
    (_, payload) => published.push(payload),
    invalidate_workspaces=fn(_, _) {  },
    release_worktree=fn(_) {  },
  )
  assert_eq(actor.session_revision, 7)
  let revision = match published.get(0) {
    Some(Object(fields)) => @jsonx.json_int(fields, "sessionRevision")
    _ => None
  }
  assert_eq(revision, Some(7))
}

///|
async test "dsh actor publishes session removal after worktree release failure" {
  let actor = Actor()
  let published : Array[String] = []
  actor.publish_frame(
    "host",
    {
      "rpcId": "host-1",
      "payload": { "type": "host/session-removed", "sessionId": "session-1" },
    },
    (method_, _) => published.push(method_),
    invalidate_workspaces=fn(_, _) {  },
    release_worktree=_ => {
      raise RequestFailed("release-worktree", "registry is read-only")
    },
  )
  assert_eq(published, ["dsh.event"])
}

///|
async test "dsh actor invalidates grants before publishing workspace changes" {
  let actor = Actor()
  actor.generation = 9
  let order : Array[String] = []
  let invalidated : @async.Queue[(Int, Int)] = Queue(kind=Blocking(1))
  actor.publish_frame(
    "host",
    {
      "rpcId": "host-workspace-1",
      "payload": {
        "type": "host/workspace-removed",
        "workspaceId": "workspace-1",
      },
    },
    (method_, _) => order.push(method_),
    invalidate_workspaces=async fn(generation, revision) {
      invalidated.put((generation, revision))
      order.push("invalidated:\{generation}:\{revision}")
    },
    release_worktree=fn(_) {  },
  )
  assert_eq(invalidated.get(), (9, 1))
  assert_eq(order, ["invalidated:9:1", "dsh.event"])
  actor.publish_frame(
    "host",
    {
      "rpcId": "host-workspace-2",
      "payload": {
        "type": "host/workspace-changed",
        "workspaceId": "workspace-2",
      },
    },
    (method_, _) => order.push(method_),
    invalidate_workspaces=async fn(generation, revision) {
      invalidated.put((generation, revision))
      order.push("invalidated:\{generation}:\{revision}")
    },
    release_worktree=fn(_) {  },
  )
  assert_eq(invalidated.get(), (9, 2))
  assert_eq(order, [
    "invalidated:9:1", "dsh.event", "invalidated:9:2", "dsh.event",
  ])
}

///|
async test "dsh actor revokes workspaces before publishing disconnect" {
  let actor = Actor()
  actor.state = Ready
  actor.generation = 7
  let order : Array[String] = []
  let published : Array[Json] = []
  let revoked : @async.Queue[Int] = Queue(kind=Blocking(1))
  actor.finish_disconnect(
    (method_, payload) => {
      order.push(method_)
      published.push(payload)
    },
    revoke_workspaces=async fn(generation) {
      revoked.put(generation)
      order.push("revoked")
    },
  )
  assert_eq(revoked.get(), 7)
  assert_eq(order, ["revoked", "dsh.status_changed"])
  assert_eq(published, [
    {
      "status": "unavailable",
      "message": "DeepSeek Harness disconnected",
      "revision": 1,
    },
  ])
}
