# OpenSeek Protocol

`bobzhang/openseek_protocol` owns the engine's stdout event stream — the wire
contract between `openseek run` / `openseek serve` and everything that reads
them: the TUI, the desktop host, and any script consuming `run`'s stdout.

It is a **leaf module with no openseek dependencies**, split so the decoder is
portable:

| Package | Contents | Targets | Deps |
| --- | --- | --- | --- |
| `bobzhang/openseek_protocol` | `Event`, `Usage`, `to_json`, `parse` | js, wasm, wasm-gc, native | `core/json` |
| `bobzhang/openseek_protocol/emit` | `emit` (level + `to_json` + log) | native | `xlog`, above |

Only the *writer* needs `@xlog`, which is native-only. Keeping it in its own
package means a client that reads the stream does not have to be a native
binary — `desktop/frontend` compiles to js, and its decoder can now be the same
`match` the engine's encoder is checked against.

Being a module rather than a package is what lets a *different* module consume
it: `desktop/moon.work` can list `"../protocol"` as a member and bind the
working tree (a `moon.work` member wins over the registry, so there is no stale
mooncakes snapshot).

The stream doubles as the process log. `emit` routes through `@xlog`, whose
handler writes one `Entry` per line and **hoists** structured fields to the top
level, so a line looks like:

```json
{"timestamp":"…","level":"INFO","source":"agent/turn_loop.mbt:392:9","event":"assistant_delta","content":"Hel"}
```

The envelope (`timestamp`, `level`, `source`) is `@xlog`'s; everything from
`event` on is this package's.

## Why it exists

The contract used to live as anonymous JSON literals at ~55 `@xlog.info() <? {…}`
call sites, with a hand-written decoder per client. Nothing tied the two
directions together, and they had drifted:

- `tool_result` was emitted with `brief` from one site and without it from two.
- `mcp_connect_failed` was emitted with `error` from one site and without it
  from another.
- `compaction_failed` was reported at `warn` from one site and `error` from two.

`Event` closes that by construction: one variant per event, owning its payload
**and its level**, with `to_json` the only author of the shape and `parse` its
inverse. Every reader — the TUI, the desktop host, the desktop frontend —
matches on the same enum, so adding a variant is a compile error at each one:
ignoring an event is a decision someone wrote down, not a `_ => None` nobody
noticed.

What that caught, once the readers were made exhaustive:

- **`reasoning_delta`** had not been emitted since 2026-06-21 (a85d5682), yet the
  TUI and the desktop both still decoded it and rendered a live "thinking" view
  from it — under tests that passed on fabricated lines.
- **`runtime_update`** had not been emitted since 2026-07-05 (4b1ec831), yet the
  desktop host still decoded it, likewise under a passing test.
- The desktop host **synthesized `compaction_failed` with `reason`** while the
  engine writes `error`, under a comment claiming "the same wire shape the engine
  emits". One decoder happened to accept both spellings, so nothing noticed.

## API

```mbt nocheck
// Report an event. The level comes from the variant, never the call site.
@emit.emit(AssistantDelta(content="Hel"))
@emit.emit(AgentAborted(reason="interrupted"))

// Or build the line without logging it — what the desktop host forwards for a
// compaction whose engine died before reporting one itself.
let line = CompactionFailed(error="engine exited").to_json()

// Read one back. `None` means "not an event this engine emits" — an unknown
// name or a malformed payload — so a client stays tolerant of a newer engine.
match @protocol.parse(line) {
  Some(AssistantDelta(content~)) => render(content)
  Some(_) | None => ()
}
```

`emit` carries `#callsite(autofill(loc))` and forwards `loc` to `@xlog`, so each
line's `source` still points at the reporting code rather than at `emit.mbt`.

## When a field may be absent

A field is defaulted **iff it was added after its event already existed** —
engines older than the field still emit the event without it, and the clients
launch whichever `openseek` is on `PATH`. Exactly one qualifies today:
`steer_applied`'s `kind` (added 2026-06-25 in 9b2f6c43, to an event from
56140618).

"No reader uses it" is *not* a reason. `tool_call_id`, `usage`'s cache counters
and `mcp_tools_registered`'s `names` are unread by every client, yet every engine
that emitted those events emitted those fields — so absence means the line is not
what it claims, and defaulting would hide a real break behind a fabricated value.
Check `git log -S` for the field against its event's introducing commit before
adding another.

## Invariants

- **`parse` is `emit`'s inverse** for every variant. `protocol_test.mbt` pins
  this per sample; it is the property the package exists to provide.
- **Optional string fields are written as the value or `null`, never omitted.**
  A field's own `ToJson` would encode `Some(v)` as the one-element array `[v]`,
  which every decoder's string lookup rejects — silently turning a present field
  into an absent one. `or_null` is why, and the round-trip test is what caught it.
- **`Usage` is owned here, not borrowed from the provider.** It is structurally
  identical to `@deepseek.Usage` — same fields, same order, same JSON — and
  deliberately a separate type. The wire format must not be whatever a vendor's
  response struct happens to be, and this module cannot depend on the engine's
  provider layer without a cycle. `agent`'s `wire_usage` is the single place the
  two meet.

## Known gaps

- **The stream still has no identity apart from the log, and that has already
  cost a feature.** `reasoning_delta` was dropped for log noise (a85d5682) and
  silently took the clients' live-thinking view with it, because there is no way
  to send a reader something without also writing it to the log file. The engine
  now pins its own level so `MOON_XLOG` cannot silence the protocol, but that is
  a guard, not a fix: a real one gives the protocol its own sink.
