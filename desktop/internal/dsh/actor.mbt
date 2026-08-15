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
  Call(String, Json, @async.Queue[Result[Json, DshError]])
  Respond(Json, @async.Queue[Result[Json, DshError]])
  ListInteractions(@async.Queue[Result[Json, DshError]])
}

///|
priv enum DshEvent {
  Frame(String, Json)
  Disconnected
}

///|
priv enum ActorStep {
  Input(ActorInput)
  Event(DshEvent)
}

///|
const ActorInputCapacity : Int = 256

///|
const DshEventCapacity : Int = 2048

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
  mut next_rpc_id : Int
  interactions : PendingInteractionRegistry
}

///|
pub fn Actor::Actor() -> Actor {
  {
    inputs: Queue(kind=Blocking(ActorInputCapacity)),
    wake: Queue(kind=Blocking(ActorWakeCapacity)),
    state: Starting,
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
    Starting => { "status": "starting" }
    Ready => { "status": "ready" }
    Unavailable(message) => { "status": "unavailable", "message": message }
  }
}

///|
/// Queue one allowlisted ApiProxy request. The API package owns the allowlist;
/// this process owner only serializes the physical carrier envelope.
pub async fn Actor::call(
  self : Actor,
  method_~ : String,
  payload~ : Json,
) -> Json {
  let reply : @async.Queue[Result[Json, DshError]] = Queue(kind=Blocking(1))
  self.inputs.put(Call(method_, payload, reply))
  self.signal()
  match reply.get() {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
/// Queue one complete client-response for a pending dsh approval or question.
pub async fn Actor::respond(self : Actor, message : Json) -> Json {
  let reply : @async.Queue[Result[Json, DshError]] = Queue(kind=Blocking(1))
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
pub async fn Actor::run(self : Actor, emit : (String, Json) -> Unit) -> Unit {
  let mut first = true
  for ;; {
    let pending = if first {
      first = false
      None
    } else {
      Some(self.inputs.get())
    }
    @async.with_task_group(group => self.run_connection(group, pending, emit))
  }
}

///|
async fn[G] Actor::run_connection(
  self : Actor,
  group : @async.TaskGroup[G],
  pending : ActorInput?,
  emit : (String, Json) -> Unit,
) -> Unit {
  self.state = Starting
  // Requests from an older WebSocket generation cannot be answered on this
  // connection. The new mux baseline will repopulate still-pending requests.
  self.interactions.reset()
  emit("dsh.status_changed", self.status())
  let events : @async.Queue[DshEvent] = Queue(kind=Blocking(DshEventCapacity))
  let connection = Connection::connect(group) catch {
    error if @async.is_being_cancelled() => raise error
    error => {
      // Connection startup errors already distinguish executable lookup,
      // readiness timeout, and dsh's own stderr. Preserve that explanation
      // for the frontend instead of misreporting every failure as PATH.
      let message = "\{error}"
      self.state = Unavailable(message)
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
      (events.try_put(Disconnected) catch { _ => false }) |> ignore
      self.signal()
    })
  }
  self.state = Ready
  emit("dsh.status_changed", self.status())
  if pending is Some(input) {
    connection.dispatch_input(group, self, input)
  }
  for ;; {
    let next = self.next_step(events) catch {
      error if @async.is_being_cancelled() => raise error
      _ => break
    }
    match next {
      Input(input) => connection.dispatch_input(group, self, input)
      Event(Frame(stream, message)) => {
        if stream == "mux" {
          self.interactions.observe(message)
        }
        emit("dsh.event", {
          "stream": stream,
          "message": message,
          "generation": self.interactions.generation,
        })
      }
      Event(Disconnected) => break
    }
  }
  connection.shutdown()
  self.state = Unavailable("DeepSeek Harness disconnected")
  emit("dsh.status_changed", self.status())
}

///|
async fn Actor::next_step(
  self : Actor,
  events : @async.Queue[DshEvent],
) -> ActorStep {
  for ;; {
    if (self.inputs.try_get() catch { _ => None }) is Some(input) {
      return Input(input)
    }
    let event = events.try_get() catch { _ => return Event(Disconnected) }
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
    Call(_, _, reply) | Respond(_, reply) | ListInteractions(reply) =>
      (reply.try_put(Err(error)) catch { _ => false }) |> ignore
  }
}

///|
fn[G] Connection::dispatch_input(
  self : Connection,
  group : @async.TaskGroup[G],
  actor : Actor,
  input : ActorInput,
) -> Unit {
  match input {
    Call(method_, payload, reply) => {
      actor.next_rpc_id += 1
      let rpc_id = "openseek-desktop-\{actor.next_rpc_id}"
      group.spawn_bg(allow_failure=true, () => {
        let outcome : Result[Json, DshError] = try
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
          value => Ok(value)
        }
        (reply.try_put(outcome) catch { _ => false }) |> ignore
      })
    }
    Respond(message, reply) =>
      group.spawn_bg(allow_failure=true, () => {
        let outcome : Result[Json, DshError] = try self.respond(message) catch {
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
          value => Ok(value)
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
  let reply : @async.Queue[Result[Json, DshError]] = Queue(kind=Blocking(1))
  actor.inputs.put(Call("session.list", {}, reply))
  let step = actor.next_step(events)
  assert_true(step is Input(Call("session.list", _, _)))
}
