///|
/// The severity an event is reported at.
///
/// A property of the event, not of the call site: `compaction_failed` was once
/// logged at `warn` from one place and `error` from two, which no reader could
/// see and nothing could catch. It lives here rather than beside `Event`
/// because `@xlog` is native-only and the decoder has to stay portable.
fn level(event : @protocol.Event) -> @xlog.Level {
  match event {
    AgentSetupFailed(_)
    | TurnFailed(_)
    | ToolCallDecodeError(..)
    | CompactionFailed(_)
    | SessionError(_)
    | CommandError(_) => Error
    AgentAborted(_)
    | MaxStepsExhausted
    | SteerDropped(_)
    | GoalBudgetExhausted(_)
    | AutoCompactionFailed(_)
    | McpConfigIgnored(_)
    | McpConfigUnreadable(..)
    | McpConfigInvalid(..)
    | McpToolDuplicate(..)
    | McpToolRenamed(..)
    | McpToolsCapped(..)
    | McpServerSkippedOverCap(_)
    | McpConnectFailed(..)
    | McpListToolsFailed(..)
    | McpListToolsTimeout(_)
    | McpNoTools(_) => Warn
    _ => Info
  }
}

///|
/// Write `event` to the process log, which is the engine's stdout JSONL stream.
///
/// `loc` is autofilled from the *caller*, then forwarded to `@xlog`, so each
/// line's `source` still points at the code that reported the event rather than
/// at this function.
///
/// The shape comes from `Event::to_json` — the one encoder — so the engine and
/// the desktop host, which forwards a synthesized event of its own, cannot
/// spell the same event two ways. They did once.
///
/// `@xlog.event` returns `None` when the level is disabled, and that is checked
/// before serializing, so a filtered event costs nothing beyond the enum it was
/// handed.
#callsite(autofill(loc))
pub fn emit(event : @protocol.Event, loc~ : SourceLoc) -> Unit {
  guard @xlog.event(level(event), loc~) is Some(entry) else { return }
  guard event.to_json() is Object(fields) else { return }
  entry.write_object_begin()
  for key, value in fields {
    entry.write_object_field(key, value)
  }
  entry.write_object_end()
}

///|
/// A per-loop event destination. The engine's top-level loop uses the
/// process-log sink (`EventSink::global`); a nested agent loop — a sub-run
/// such as the review engine, once it runs inside a live session — installs
/// an isolating sink so its lifecycle and progress events stay out of the
/// host-facing stream, where a child's `AgentFinished` would read as the
/// OUTER run's terminal (the TUI and desktop hosts both treat any
/// `AgentFinished` as run-terminal). The wrapped function receives the
/// original call site, so forwarded log lines keep pointing at the code
/// that reported the event, not at the sink.
pub(all) struct EventSink((@protocol.Event, SourceLoc) -> Unit)

///|
/// Forward an event to this sink, autofilling the caller's location.
#callsite(autofill(loc))
pub fn EventSink::emit(
  self : EventSink,
  event : @protocol.Event,
  loc~ : SourceLoc,
) -> Unit {
  (self.0)(event, loc)
}

///|
/// The process-log sink: forwards to `emit`, preserving the reporting call
/// site. Every top-level loop uses this; it is the behavior-preserving
/// default wherever a sink parameter is accepted.
pub fn EventSink::global() -> EventSink {
  EventSink((event, loc) => emit(event, loc~))
}
