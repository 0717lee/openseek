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
struct Actor {
  inputs : @async.Queue[ActorInput]
  wake : @async.Queue[Unit]
  mut state : ConnectionState
  mut next_rpc_id : Int
}

///|
pub fn Actor::Actor() -> Actor {
  {
    inputs: Queue(kind=Blocking(ActorInputCapacity)),
    wake: Queue(kind=Blocking(ActorWakeCapacity)),
    state: Starting,
    next_rpc_id: 0,
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
      Event(Frame(stream, message)) =>
        emit("dsh.event", { "stream": stream, "message": message })
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
    Call(_, _, reply) | Respond(_, reply) =>
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
  }
}

///|
async test "dsh actor consumes a buffered command before events" {
  let actor = Actor()
  let events : @async.Queue[DshEvent] = Queue(kind=Blocking(1))
  let reply : @async.Queue[Result[Json, DshError]] = Queue(kind=Blocking(1))
  actor.inputs.put(Call("session.list", {}, reply))
  let step = actor.next_step(events)
  assert_true(step is Input(Call("session.list", _, _)))
}
