# OpenSeek Agent Session

`bobzhang/openseek/agent_session` is the typed, provider-aware conversation
state for resumable OpenSeek agents. It is intentionally separate from the TUI
transcript model: session values are persisted and projected into DeepSeek chat
messages, while transcript values are optimized for terminal rendering.

The package exposes:

- `SessionId` and immutable `Session`
- append-only `SessionEvent` sequence numbers backed by an immutable vector
- typed `SessionItem` variants for users, assistants, tool results, runtime
  notices, summaries, and turn terminal states
- JSON round-tripping for durable storage
- `Session::append_event` for callers that need the new session and appended
  event without scanning the whole event log
- `Session::chat_messages` for projecting a session into DeepSeek protocol
  messages
- `Session::compact` for appending a validated summary that replaces covered
  source events in model-facing projection while keeping the raw log intact

```mbt check
///|
test {
  let session = @agent_session.Session(
    SessionId("example"),
    system_prompt="system",
  ).append(User(UserMessage("hello")))
  inspect(session.last_sequence(), content="1")
}
```
