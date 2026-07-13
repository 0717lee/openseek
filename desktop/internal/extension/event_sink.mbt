// Native event adapters for the shared desktop bridge. Operation payload and
// reply DTOs live in `internal/protocol`; engine events remain engine-domain
// values and are emitted to the webview here.

///|
fn event_sink(context : @app.AppCommandExtensionContext) -> @engine.EventSink {
  EventSink(async fn(event) { emit_engine_event(context, event) })
}

///|
async fn emit_engine_event(
  context : @app.AppCommandExtensionContext,
  event : @engine.EngineEvent,
) -> Unit {
  match event {
    Connected(payload) => context.emit("connected", payload)
    Started(payload) => context.emit("started", payload)
    StreamEvent(payload) => context.emit("event", payload)
    Error(payload) => context.emit("error", payload)
    Finished(payload) => {
      notify_run_finished(payload)
      context.emit("finished", payload)
    }
  }
}
