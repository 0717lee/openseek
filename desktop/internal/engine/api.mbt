///|
pub(all) suberror EngineError {
  EngineError(String)
}

///|
impl Show for EngineError with fn output(self, logger) {
  match self {
    EngineError(message) => logger.write_string(message)
  }
}

///|
struct ConnectedPayload {
  ready : Bool
} derive(ToJson)

///|
struct StartedPayload {
  run_id : Int
  task : String
  engine : String
  model : String
  max_steps : Int
  cwd : String?
  session : String?
  session_root : String?
} derive(ToJson)

///|
struct EventPayload {
  run_id : Int
  // The conversation the event belongs to (the engine's session key, "" for
  // a session-less engine). Idle events — the compaction lifecycle and
  // background notices — are routed by it: run-id routing needs a `Started`
  // event this app-lifetime, which a conversation resumed and compacted
  // before its first prompt never had.
  session : String
  event : Json
} derive(ToJson)

///|
pub struct FinishedPayload {
  run_id : Int
  status : String
  answer : String?
  exit_code : Int?
} derive(ToJson)

///|
struct ErrorPayload {
  run_id : Int?
  message : String
  exit_code : Int?
  diagnostics : String?
} derive(ToJson)

///|
pub(all) enum EngineEvent {
  Connected(ConnectedPayload)
  Started(StartedPayload)
  StreamEvent(EventPayload)
  Error(ErrorPayload)
  Finished(FinishedPayload)
}

///|
pub(all) struct EventSink(async (EngineEvent) -> Unit)

///|
priv enum RunStatus {
  Finished
  ContextYield
  Aborted
  Failed
  Cancelled
  MaxStepsExhausted
}

///|
fn RunStatus::wire(self : RunStatus) -> String {
  match self {
    Finished => "finished"
    ContextYield => "context_yield"
    Aborted => "aborted"
    Failed => "failed"
    Cancelled => "cancelled"
    MaxStepsExhausted => "max_steps_exhausted"
  }
}

///|
async fn emit(sink : EventSink, event : EngineEvent) -> Unit {
  sink(event)
}

///|
async fn emit_error(
  sink : EventSink,
  message : String,
  run_id? : Int,
  exit_code? : Int,
  diagnostics? : String,
) -> Unit {
  emit(sink, Error({ run_id, message, exit_code, diagnostics }))
}

///|
async fn emit_finished(
  sink : EventSink,
  run_id : Int,
  status : RunStatus,
  answer? : String,
  exit_code? : Int,
) -> Unit {
  emit(sink, Finished({ run_id, status: status.wire(), answer, exit_code }))
}
