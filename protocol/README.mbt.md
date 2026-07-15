# OpenSeek Protocol

`bobzhang/openseek_protocol` owns the engine's stdout event stream — the wire
contract between `openseek run` / `openseek serve` and everything that reads
them: the TUI, the desktop host, and any script consuming `run`'s stdout.

It is a **leaf module with no openseek dependencies**, split so the decoder is
portable:

| Package | Contents | Targets | Deps |
| --- | --- | --- | --- |
| `bobzhang/openseek_protocol` | `Event`, `Usage`, `parse` | js, wasm, wasm-gc, native | `core/json` |
| `bobzhang/openseek_protocol/emit` | `emit` | native | `xlog`, above |

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
**and its level**, with `emit` and `parse` as the only writer and reader.
Because every client matches on the same enum, adding a variant is a compile
error at each one — ignoring an event becomes a decision someone wrote down
rather than a `_ => None` nobody noticed.

## API

```mbt nocheck
// Report an event. The level comes from the variant, never the call site.
@protocol.emit(AssistantDelta(content="Hel"))
@protocol.emit(AgentAborted(reason="interrupted"))

// Read one back. `None` means "not an event this engine emits" — an unknown
// name or a malformed payload — so a client stays tolerant of a newer engine.
match @protocol.parse(line) {
  Some(AssistantDelta(content~)) => render(content)
  Some(_) | None => ()
}
```

`emit` carries `#callsite(autofill(loc))` and forwards `loc` to `@xlog`, so each
line's `source` still points at the reporting code rather than at `emit.mbt`.

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

- The stream is filterable. `@xlog`'s root level comes from `MOON_XLOG`, so
  `MOON_XLOG=warn openseek serve` drops every `info` event — `assistant_delta`,
  `agent_step`, `usage`, `session_started` — and a client sees nothing. The
  protocol should not be silenceable by a logging environment variable.
- The clients still hand-decode. The TUI (`cmd/tui/internal/event/`) and the
  desktop (`desktop/internal/event/`, `desktop/frontend/transcript/`) each keep
  their own reader; adopting `parse` is what turns the drift table above into a
  compile error. The desktop additionally needs `"../protocol"` added to
  `desktop/moon.work`.
