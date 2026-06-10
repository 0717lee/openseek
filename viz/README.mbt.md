# OpenSeek session visualizer

A browser viewer for OpenSeek's durable session logs. It renders the
`events.jsonl` append-only log of a session two ways, side by side behind a
toggle:

- **Raw log** — every event in file order, grouped into turns (user prompt →
  assistant messages, tool results, runtime notices, terminal).
- **Model view** — exactly what `Session::chat_messages` feeds the model:
  summaries replace the events they cover, and tool calls left dangling by a
  crashed process show the synthesized "previous agent process exited…" marker.

A Light / Dark / System theme toggle sits in the sidebar (default Light;
System follows the OS via `prefers-color-scheme`).

## Pieces

| Package          | Target | Role                                                                 |
|------------------|--------|---------------------------------------------------------------------|
| `viz`            | js     | Pure parse + render: `events.jsonl` text → typed events → `@html.Html`. Reuses `agent_session` decoders and projection, so it stays correct as the format evolves. |
| `cmd/viz_app`    | js     | The rabbita (TEA) frontend: session browser, fetch, mode toggle.    |
| `cmd/viz_server` | native | Read-only web server (`moonbitlang/async/http`) exposing a JSON/raw-file API over a `SessionStore`. It never writes, so pointing it at a live session root is safe. |

The `viz` library is headless-testable: `render_session` returns `@html.Html`,
which `@rabbita.render_to_string` turns into a string for snapshot assertions —
no browser needed in CI.

## Server API

- `GET /` → the viewer shell (`web/index.html`)
- `GET /viz_app.js` → the compiled frontend bundle (auto-located from the moon build output)
- `GET /api/sessions` → `[{id, last_active, first_prompt}, …]`, most recent first
- `GET /api/sessions/<id>/events.jsonl` → raw append-only log
- `GET /api/sessions/<id>/session.json` → raw header (404 when absent; the frontend degrades to events-only)

## Running it

```bash
# 1. Build the frontend bundle (JS backend)
moon build cmd/viz_app --target js

# 2. Serve a session root (the server finds the bundle from the build output)
moon run cmd/viz_server --target native -- --session-root .openseek --port 8080

# 3. Open http://127.0.0.1:8080
```

`--session-root`, `--port`, `--web-dir`, and `--bundle` all have env-var
fallbacks (`OPENSEEK_SESSION_ROOT`, `OPENSEEK_VIZ_PORT`, …); run with `--help`
for the full list.

## Resilient parsing

`parse_events` tolerates a half-written log: a truncated final line (a process
that exited between writing an event and its newline) is reported as a benign
truncated tail, and any single line that fails to decode becomes an inline error
card while the rest of the conversation still renders.
