///|
/// Stable identifier for a persisted OpenSeek conversation.
pub struct SessionId {
  priv value : String
} derive(Debug)

///|
pub fn SessionId::SessionId(value : String) -> SessionId {
  { value, }
}

///|
pub fn SessionId::value(self : SessionId) -> String {
  self.value
}

///|
/// User-authored model input for one conversational turn.
pub struct UserMessage {
  priv content : String
} derive(Debug, ToJson, FromJson)

///|
priv struct SessionToolCall {
  id : String
  name : String
  arguments : String
} derive(Debug, ToJson, FromJson)

///|
fn SessionToolCall::from_deepseek(call : @deepseek.ToolCall) -> SessionToolCall {
  { id: call.id, name: call.name, arguments: call.arguments }
}

///|
fn SessionToolCall::to_deepseek(self : SessionToolCall) -> @deepseek.ToolCall {
  ToolCall(id=self.id, name=self.name, arguments=self.arguments)
}

///|
pub fn UserMessage::UserMessage(content : String) -> UserMessage {
  { content, }
}

///|
pub fn UserMessage::content(self : UserMessage) -> String {
  self.content
}

///|
/// Assistant output returned by the model. Native DeepSeek tool calls are kept
/// in their typed protocol form so replay can preserve call ids and raw
/// argument strings exactly.
pub struct AssistantMessage {
  priv content : String
  priv tool_calls : Array[SessionToolCall]
  priv reasoning_content : String?
} derive(Debug, ToJson, FromJson)

///|
pub fn AssistantMessage::AssistantMessage(
  content : String,
  tool_calls? : Array[@deepseek.ToolCall] = [],
  reasoning_content? : String,
) -> AssistantMessage {
  {
    content,
    tool_calls: [
      for call in tool_calls => SessionToolCall::from_deepseek(call)
    ],
    reasoning_content,
  }
}

///|
pub fn AssistantMessage::content(self : AssistantMessage) -> String {
  self.content
}

///|
fn AssistantMessage::tool_calls(
  self : AssistantMessage,
) -> Array[@deepseek.ToolCall] {
  [
    for call in self.tool_calls => call.to_deepseek()
  ]
}

///|
fn AssistantMessage::reasoning_content(self : AssistantMessage) -> String? {
  self.reasoning_content
}

///|
/// Result returned by a local tool for one assistant tool call.
pub struct ToolResult {
  priv tool_call_id : String
  priv tool_name : String
  priv content : String
  priv is_error : Bool
} derive(Debug, ToJson, FromJson)

///|
pub fn ToolResult::ToolResult(
  tool_call_id~ : String,
  tool_name~ : String,
  content~ : String,
  is_error? : Bool = false,
) -> ToolResult {
  { tool_call_id, tool_name, content, is_error }
}

///|
fn ToolResult::tool_call_id(self : ToolResult) -> String {
  self.tool_call_id
}

///|
pub fn ToolResult::tool_name(self : ToolResult) -> String {
  self.tool_name
}

///|
pub fn ToolResult::content(self : ToolResult) -> String {
  self.content
}

///|
pub fn ToolResult::is_error(self : ToolResult) -> Bool {
  self.is_error
}

///|
/// Out-of-band runtime update that was surfaced to the model, such as a
/// `moon_check --watch` diagnostic batch.
pub struct RuntimeNotice {
  priv content : String
} derive(Debug, ToJson, FromJson)

///|
pub fn RuntimeNotice::RuntimeNotice(content : String) -> RuntimeNotice {
  { content, }
}

///|
pub fn RuntimeNotice::content(self : RuntimeNotice) -> String {
  self.content
}

///|
/// Durable compaction of older session events. The `event_range` names the
/// inclusive source range summarized so future refactors can verify what was
/// compacted without depending on string parsing.
pub struct SessionSummary {
  priv content : String
  priv from_sequence : Int
  priv to_sequence : Int
} derive(Debug, ToJson, FromJson)

///|
pub fn SessionSummary::SessionSummary(
  content~ : String,
  from_sequence~ : Int,
  to_sequence~ : Int,
) -> SessionSummary {
  { content, from_sequence, to_sequence }
}

///|
pub fn SessionSummary::content(self : SessionSummary) -> String {
  self.content
}

///|
pub fn SessionSummary::from_sequence(self : SessionSummary) -> Int {
  self.from_sequence
}

///|
pub fn SessionSummary::to_sequence(self : SessionSummary) -> Int {
  self.to_sequence
}

///|
pub(all) enum TurnTerminal {
  Finished(String)
  Aborted(String)
  Interrupted(String)
  Failed(String)
} derive(Debug)

///|
pub(all) enum SessionItem {
  User(UserMessage)
  Assistant(AssistantMessage)
  Tool(ToolResult)
  Runtime(RuntimeNotice)
  Summary(SessionSummary)
  Terminal(TurnTerminal)
} derive(Debug)

///|
/// One append-only session event. Sequence numbers are one-based and monotonic
/// within a session.
pub struct SessionEvent {
  priv sequence : Int
  priv item : SessionItem
} derive(Debug, ToJson, FromJson)

///|
fn SessionEvent::SessionEvent(
  sequence~ : Int,
  item~ : SessionItem,
) -> SessionEvent {
  { sequence, item }
}

///|
pub fn SessionEvent::sequence(self : SessionEvent) -> Int {
  self.sequence
}

///|
pub fn SessionEvent::item(self : SessionEvent) -> SessionItem {
  self.item
}

///|
/// Immutable model of an OpenSeek conversation. Mutating operations return a new
/// `Session` with copied event storage so callers do not share mutable arrays
/// across package boundaries.
pub struct Session {
  priv id : SessionId
  priv system_prompt : String
  priv events : Array[SessionEvent]
} derive(Debug)

///|
pub fn Session::Session(
  id : SessionId,
  system_prompt~ : String,
  events? : Array[SessionEvent] = [],
) -> Session {
  { id, system_prompt, events: events.copy() }
}

///|
pub fn Session::id(self : Session) -> SessionId {
  self.id
}

///|
pub fn Session::system_prompt(self : Session) -> String {
  self.system_prompt
}

///|
pub fn Session::events(self : Session) -> Array[SessionEvent] {
  self.events.copy()
}

///|
pub fn Session::last_sequence(self : Session) -> Int {
  let mut last = 0
  for event in self.events {
    if event.sequence > last {
      last = event.sequence
    }
  }
  last
}

///|
fn Session::next_sequence(self : Session) -> Int {
  self.last_sequence() + 1
}

///|
pub fn Session::append(self : Session, item : SessionItem) -> Session {
  let events = self.events.copy()
  events.push(SessionEvent(sequence=self.next_sequence(), item~))
  Session(self.id, system_prompt=self.system_prompt, events~)
}

///|
/// Append a validated summary event that compacts a contiguous range of existing
/// events in model-facing projection while preserving those events in the
/// durable append-only log.
pub fn Session::compact(
  self : Session,
  content~ : String,
  from_sequence~ : Int,
  to_sequence~ : Int,
) -> Session raise {
  if content.trim().is_empty() {
    fail("summary content must not be empty")
  }
  if from_sequence <= 0 {
    fail("summary from_sequence must be positive")
  }
  if to_sequence < from_sequence {
    fail("summary to_sequence must be >= from_sequence")
  }
  let last = self.last_sequence()
  if to_sequence > last {
    fail(
      "summary range \{from_sequence}..\{to_sequence} exceeds last sequence \{last}",
    )
  }
  self.append(Summary(SessionSummary(content~, from_sequence~, to_sequence~)))
}
