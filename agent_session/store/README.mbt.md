# OpenSeek Agent Session Store

`bobzhang/openseek/agent_session/store` is the native filesystem persistence
layer for typed OpenSeek sessions. It wraps `agent_session.Session` with the
filesystem rules needed to save, resume, list, and compact durable
conversations.

The package is native-only because it uses `moonbitlang/async/fs` for files,
directory mtimes, and advisory locks.

## Layout

Each session lives under:

```text
<root>/sessions/<session-id>/
  session.json
  events.jsonl
  session.lock
```

`session.json` stores the small header: session id, system prompt, last
sequence, and a fingerprint of the event-log prefix it describes.
`events.jsonl` is the append-only stream of typed `SessionEvent` records. Loading
replays the JSONL log into an immutable `agent_session.Session`.

`session.lock` is an implementation detail used to serialize writers and keep a
reader from seeing a half-updated session.

## API Shape

The root API is small:

```mbt nocheck
let store = @store.SessionStore(".openseek")

store.create(session) // create or replace a complete session
let session = store.load(@agent_session.SessionId("demo"))
let session = store.append(session, User(UserMessage("hello")))
let session = store.compact(
  session,
  content="summary text",
  from_sequence=1,
  to_sequence=20,
)
```

Use `create` when writing a complete session snapshot. Use `append` for normal
agent progress. `append` is the safe save path: it checks that the caller's
in-memory session still matches disk, appends exactly one timestamped event, and
updates the header.

`load` takes a `SessionId` because `SessionStore(root)` is a directory-backed
collection, not a handle to one current session. The id selects
`<root>/sessions/<id>/session.json` and
`<root>/sessions/<id>/events.jsonl`; the store intentionally does not keep a
hidden "current" session. When the caller needs to discover a session first,
use `list`, `listings`, or `latest`, then pass the chosen id to `load`.

## Create And Load

`create` writes a complete session. It is useful for new sessions, test
fixtures, or deliberate rewrites. `load` reads the header, replays the JSONL
events for the requested id, validates sequence numbers, and rebuilds the
immutable `Session`.

More pedantically, `load(id)`:

- validates `id` before using it in a path;
- takes a shared session lock when the session directory exists;
- reads `session.json` and checks that the header id equals the requested id;
- parses every JSON line in `events.jsonl` as a typed `SessionEvent`;
- checks that event sequence numbers are contiguous;
- validates the header's event-log fingerprint against the replayed log;
- returns a rebuilt immutable `Session`;
- does not create a missing session, choose a latest session, or mutate disk.

Use `exists(id)` when absence is expected. Use `latest()` when implementing a
default "resume" action. Use `list()` or `listings()` when a human or caller
must choose the id before loading.

```mbt check
///|
async test "create and load a complete session" {
  @vfs.with_tmpdir(prefix="openseek-store-readme-create-", root => {
    let store = @store.SessionStore(root)
    let session = @agent_session.Session(
        SessionId("demo"),
        system_prompt="system",
      )
      .append(User(UserMessage("hello")))
      .append(Terminal(Finished("done")))

    store.create(session)
    let loaded = store.load(SessionId("demo"))
    debug_inspect(
      loaded,
      content=(
        #|{
        #|  id: { value: "demo" },
        #|  system_prompt: "system",
        #|  events: <Vector:
        #|    [
        #|      { sequence: 1, ts: 0, item: User({ content: "hello" }) },
        #|      { sequence: 2, ts: 0, item: Terminal(Finished("done")) },
        #|    ]>,
        #|  last_sequence: 2,
        #|}
      ),
    )
  })
}
```

## Append

`append` is what the CLI, TUI, and serve mode use while an agent turn is
running. It returns the new in-memory session value, so callers should keep using
the returned session for the next append.

The store stamps appended events with the current wall clock. For documentation,
the example snapshots the model projection rather than raw events, keeping the
example stable while still showing the resumed conversation shape.

```mbt check
///|
async test "append saves progress and load resumes it" {
  @vfs.with_tmpdir(prefix="openseek-store-readme-append-", root => {
    let store = @store.SessionStore(root)
    let session = @agent_session.Session(
      SessionId("demo"),
      system_prompt="system",
    )

    store.create(session)
    let session = store.append(session, User(UserMessage("inspect README")))
    ignore(store.append(session, Terminal(Finished("done"))))

    let loaded = store.load(SessionId("demo"))
    debug_inspect(
      loaded.chat_messages(),
      content=(
        #|[
        #|  {
        #|    role: System,
        #|    content: "system",
        #|    tool_calls: [],
        #|    reasoning_content: None,
        #|  },
        #|  {
        #|    role: User,
        #|    content: "inspect README",
        #|    tool_calls: [],
        #|    reasoning_content: None,
        #|  },
        #|  {
        #|    role: Assistant,
        #|    content: "done",
        #|    tool_calls: [],
        #|    reasoning_content: None,
        #|  },
        #|]
      ),
    )
  })
}
```

If another writer has already appended to the same session, appending from an
old in-memory value fails with a stale-snapshot error instead of silently
forking the log:

```mbt check
///|
async test "append rejects a stale in-memory session" {
  @vfs.with_tmpdir(prefix="openseek-store-readme-stale-", root => {
    let store = @store.SessionStore(root)
    let session = @agent_session.Session(
      SessionId("demo"),
      system_prompt="system",
    )

    store.create(session)
    ignore(store.append(session, User(UserMessage("first"))))
    let result = try store.append(session, User(UserMessage("stale"))) catch {
      error => "error: \{error}".contains("stale session snapshot")
    } noraise {
      _ => false
    }
    debug_inspect(
      result,
      content=(
        #|true
      ),
    )
  })
}
```

## Compact

`compact` appends a validated `Summary` event. It does not rewrite
`events.jsonl`; the raw covered events remain durable. The compaction effect is
visible when `Session::chat_messages` projects model context: covered earlier
events are skipped and the later summary message is used instead.

```mbt check
///|
async test "compact appends a durable summary" {
  @vfs.with_tmpdir(prefix="openseek-store-readme-compact-", root => {
    let store = @store.SessionStore(root)
    let session = @agent_session.Session(
        SessionId("demo"),
        system_prompt="system",
      )
      .append(User(UserMessage("old user")))
      .append(Assistant(AssistantMessage("old assistant")))

    store.create(session)
    ignore(
      store.compact(
        session,
        content="old user and assistant discussed README",
        from_sequence=1,
        to_sequence=2,
      ),
    )

    let loaded = store.load(SessionId("demo"))
    debug_inspect(
      loaded.chat_messages(),
      content=(
        #|[
        #|  {
        #|    role: System,
        #|    content: "system",
        #|    tool_calls: [],
        #|    reasoning_content: None,
        #|  },
        #|  {
        #|    role: User,
        #|    content: "[conversation summary]\nsource_events=1..2\nold user and assistant discussed README",
        #|    tool_calls: [],
        #|    reasoning_content: None,
        #|  },
        #|]
      ),
    )
  })
}
```

## Listing And Resume

Use `list` when all you need is sorted ids. Use `listings` when building a human
picker: each row has an id, last-activity timestamp, and first user prompt.
`latest` is stricter than `listings`: it probes candidates with `load` and
returns the newest loadable session id, skipping torn sessions.

```mbt check
///|
async test "list sessions by id" {
  @vfs.with_tmpdir(prefix="openseek-store-readme-list-", root => {
    let store = @store.SessionStore(root)

    store.create(Session(SessionId("b"), system_prompt="system"))
    store.create(Session(SessionId("a"), system_prompt="system"))
    debug_inspect(
      [
        for id in store.list() => id.value()
      ],
      content=(
        #|["a", "b"]
      ),
    )
  })
}
```

`listings` keeps damaged session directories visible so users can find and clean
them up. `latest` uses loadability as the resume gate.

## File Path Helpers

`header_file` and `event_log_file` expose absolute paths for read-only tooling
such as the visualizer server. They still validate the session id before
constructing the path.

```mbt nocheck
///|
let header = store.header_file(@agent_session.SessionId("demo"))

///|
let log = store.event_log_file(@agent_session.SessionId("demo"))
```

## Failure Model

The store is designed around append-only progress and crash recovery:

- `append` writes the JSONL event first, then the header. A log that is ahead of
  the header is accepted on load.
- `create` writes a restrictive header before rewriting the log, then writes a
  permissive header after the rewrite succeeds. A stale tail after a rewrite is
  rejected.
- Every load checks contiguous sequence numbers and header/log fingerprints.
- Every append or compact checks that the caller's session still matches disk.

These rules keep persistence concerns out of `agent_session.Session` while
giving CLI, TUI, serve mode, and visualization code one shared durable boundary.
