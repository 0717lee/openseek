///|
/// One row of the `/api/sessions` listing shown in the sidebar. The server
/// already returns rows most-recently-active first, so the row only needs an id
/// and a human label.
struct SessionRow {
  id : String
  first_prompt : String
}

///|
/// The whole viewer state. The current session is kept as the parsed log plus a
/// system prompt fetched from `session.json`; the typed `Session` and its model
/// projection are rebuilt in `view` so the two view modes always agree with the
/// bytes on disk.
struct Model {
  sessions : Array[SessionRow]
  selected : String?
  parsed : @viz.ParsedLog?
  system_prompt : String
  header_present : Bool
  view_mode : @viz.ViewMode
  theme : Theme
  loading : Bool
  status : String
}

///|
/// Colour theme. `Light` is the default; `System` follows the OS via a CSS
/// `prefers-color-scheme` media query (so it tracks live OS changes without any
/// listener). The choice is applied by setting `data-theme` on `<html>`.
enum Theme {
  Light
  Dark
  System
} derive(Eq)

///|
fn Theme::value(self : Theme) -> String {
  match self {
    Light => "light"
    Dark => "dark"
    System => "system"
  }
}

///|
/// Messages driving the update loop. The `String` in the fetch results carries
/// the session id the request was issued for, so a slow response for a session
/// the user already navigated away from is discarded instead of clobbering the
/// pane.
enum Msg {
  SessionsFetched(Result[String, Error])
  Select(String)
  SessionFetched(String, Result[String, Error])
  SetMode(@viz.ViewMode)
  SetTheme(Theme)
}

///|
/// Outcome of decoding the `/api/sessions/<id>` envelope. `rabbita/http` reports
/// any completed response as `Ok`, so absence and malformed payloads are
/// distinguished here from the body, not the HTTP status.
enum LoadOutcome {
  Loaded(@viz.ParsedLog, String, Bool)
  NotFound
  Malformed
}

///|
fn init_model() -> Model {
  {
    sessions: [],
    selected: None,
    parsed: None,
    system_prompt: "",
    header_present: false,
    view_mode: RawLog,
    theme: Light,
    loading: false,
    status: "loading sessions…",
  }
}

// ---- update ----------------------------------------------------------------

///|
fn update(emit : @cmd.Emit[Msg], msg : Msg, model : Model) -> (@cmd.Cmd, Model) {
  match msg {
    SessionsFetched(Ok(text)) =>
      match parse_session_rows(text) {
        Some(sessions) =>
          (
            @cmd.none,
            { ..model, sessions, status: "\{sessions.length()} session(s)" },
          )
        None =>
          (@cmd.none, { ..model, status: "could not read the session list" })
      }
    SessionsFetched(Err(error)) =>
      (@cmd.none, { ..model, status: "failed to list sessions: \{error}" })
    Select(id) => {
      let command = fetch_text(emit, session_url(id), result => {
        SessionFetched(id, result)
      })
      (
        command,
        {
          ..model,
          selected: Some(id),
          parsed: None,
          system_prompt: "",
          header_present: false,
          loading: true,
          status: "loading \{id}…",
        },
      )
    }
    SessionFetched(id, result) =>
      // Drop a response for a session the user already navigated away from.
      if model.selected != Some(id) {
        (@cmd.none, model)
      } else {
        match result {
          Err(error) =>
            (
              @cmd.none,
              { ..model, loading: false, status: "request failed: \{error}" },
            )
          Ok(text) =>
            match parse_load(text) {
              Loaded(parsed, system_prompt, header_present) =>
                (
                  @cmd.none,
                  {
                    ..model,
                    parsed: Some(parsed),
                    system_prompt,
                    header_present,
                    loading: false,
                    status: events_status(parsed),
                  },
                )
              NotFound =>
                (
                  @cmd.none,
                  {
                    ..model,
                    parsed: None,
                    loading: false,
                    status: "session not found: \{id}",
                  },
                )
              Malformed =>
                (
                  @cmd.none,
                  {
                    ..model,
                    parsed: None,
                    loading: false,
                    status: "malformed response for \{id}",
                  },
                )
            }
        }
      }
    SetMode(mode) => (@cmd.none, { ..model, view_mode: mode })
    SetTheme(theme) =>
      // Apply the theme as a side effect (set `data-theme` on <html>) so the CSS
      // variable blocks take over; the model tracks it for button highlighting.
      (apply_theme(theme), { ..model, theme, })
  }
}

///|
/// Set `data-theme` on the document root. `light`/`dark` pick a fixed palette;
/// `system` defers to the OS via the stylesheet's `prefers-color-scheme` query.
extern "js" fn set_document_theme(theme : String) -> Unit = "(t) => document.documentElement.setAttribute('data-theme', t)"

///|
fn apply_theme(theme : Theme) -> @cmd.Cmd {
  @cmd.effect(() => set_document_theme(theme.value()))
}

///|
fn fetch_text(
  emit : @cmd.Emit[Msg],
  url : String,
  to_msg : (Result[String, Error]) -> Msg,
) -> @cmd.Cmd {
  @http.get(url).expect_text(emit.map(to_msg))
}

///|
/// Percent-encode the id so session ids containing URL-reserved characters
/// (spaces, `?`, `#`) reach the server intact; it percent-decodes the segment.
extern "js" fn encode_uri_component(value : String) -> String = "encodeURIComponent"

///|
fn session_url(id : String) -> String {
  "/api/sessions/\{encode_uri_component(id)}"
}

///|
fn events_status(parsed : @viz.ParsedLog) -> String {
  let base = "\{parsed.events.length()} event(s)"
  if parsed.errors.is_empty() && !parsed.partial_tail {
    base
  } else {
    "\{base} · \{parsed.errors.length()} bad line(s)\{if parsed.partial_tail { " · truncated tail" } else { "" }}"
  }
}

// ---- view ------------------------------------------------------------------

///|
fn view(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  @html.div(class="app", [
    @html.aside(class="sidebar", [
      @html.div(class="sidebar-head", [
        @html.h1(class="brand", "OpenSeek sessions"),
        @html.div(class="status", model.status),
      ]),
      sidebar_list(emit, model),
      theme_toggle(emit, model),
    ]),
    @html.section(class="main", [main_pane(emit, model)]),
  ])
}

///|
fn theme_toggle(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  @html.div(class="theme-toggle", [
    theme_button(emit, model, Light, "Light"),
    theme_button(emit, model, Dark, "Dark"),
    theme_button(emit, model, System, "System"),
  ])
}

///|
fn theme_button(
  emit : @cmd.Emit[Msg],
  model : Model,
  theme : Theme,
  label : String,
) -> @html.Html {
  let classes = if model.theme == theme {
    "theme-button active"
  } else {
    "theme-button"
  }
  @html.button(class=classes, on_click=emit(SetTheme(theme)), label)
}

///|
fn sidebar_list(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  if model.sessions.is_empty() {
    return @html.div(class="sidebar-empty", "no sessions found")
  }
  let rows : Array[@html.Html] = [
    for row in model.sessions => sidebar_row(emit, model, row)
  ]
  @html.ul(class="session-list", rows)
}

///|
fn sidebar_row(
  emit : @cmd.Emit[Msg],
  model : Model,
  row : SessionRow,
) -> @html.Html {
  let selected = model.selected == Some(row.id)
  let label = if row.first_prompt.trim().is_empty() {
    row.id
  } else {
    row.first_prompt
  }
  let classes = if selected { "session-item selected" } else { "session-item" }
  @html.li(class=classes, on_click=emit(Select(row.id)), [
    @html.div(class="session-item-label", label),
    @html.div(class="session-item-id", row.id),
  ])
}

///|
fn main_pane(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  match model.selected {
    None =>
      @html.div(
        class="placeholder",
        "Select a session from the left to view it.",
      )
    Some(id) =>
      match model.parsed {
        None =>
          if model.loading {
            @html.div(class="placeholder", "Loading \{id}…")
          } else {
            @html.div(class="placeholder", model.status)
          }
        Some(parsed) => {
          let session = @viz.session_from_parse(
            parsed,
            id~,
            system_prompt=model.system_prompt,
          )
          @html.div(class="session-view", [
            header_strip(model, id),
            mode_toggle(emit, model),
            @viz.render_notices(parsed),
            @viz.render_session(session, model.view_mode),
          ])
        }
      }
  }
}

///|
fn header_strip(model : Model, id : String) -> @html.Html {
  let prompt_note = if model.header_present {
    "session.json loaded"
  } else {
    "no session.json (events only)"
  }
  @html.header(class="header-strip", [
    @html.div(class="header-id", id),
    @html.div(class="header-meta", "\{model.status} · \{prompt_note}"),
  ])
}

///|
fn mode_toggle(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  @html.div(class="mode-toggle", [
    mode_button(emit, model, RawLog, "Raw log"),
    mode_button(emit, model, ModelView, "Model view"),
  ])
}

///|
fn mode_button(
  emit : @cmd.Emit[Msg],
  model : Model,
  mode : @viz.ViewMode,
  label : String,
) -> @html.Html {
  let classes = if model.view_mode == mode {
    "mode-button active"
  } else {
    "mode-button"
  }
  @html.button(class=classes, on_click=emit(SetMode(mode)), label)
}

// ---- JSON helpers ----------------------------------------------------------

///|
/// Decode the `/api/sessions` listing. Returns `None` when the body is not a
/// JSON array (e.g. a server error body that `rabbita/http` still delivers as
/// `Ok`), so the caller can surface the failure instead of conflating it with a
/// genuinely empty `[]`.
fn parse_session_rows(text : String) -> Array[SessionRow]? {
  let json = @json.parse(text) catch { _ => return None }
  guard json is Array(items) else { return None }
  let rows : Array[SessionRow] = []
  for item in items {
    if session_row_of(item) is Some(row) {
      rows.push(row)
    }
  }
  Some(rows)
}

///|
fn session_row_of(json : Json) -> SessionRow? {
  guard json is Object(fields) else { return None }
  guard fields.get("id") is Some(String(id)) else { return None }
  let first_prompt = match fields.get("first_prompt") {
    Some(String(value)) => value
    _ => ""
  }
  Some({ id, first_prompt })
}

///|
/// Decode the `/api/sessions/<id>` envelope into a `LoadOutcome`. `header` is
/// the parsed `session.json` (or null); its `system_prompt` is lifted out when
/// present so the viewer can label the header strip and seed the model view.
fn parse_load(text : String) -> LoadOutcome {
  let json = @json.parse(text) catch { _ => return Malformed }
  guard json is Object(fields) else { return Malformed }
  let found = match fields.get("found") {
    Some(True) => true
    Some(False) => false
    _ => return Malformed
  }
  if !found {
    return NotFound
  }
  let events_text = match fields.get("events") {
    Some(String(value)) => value
    _ => return Malformed
  }
  let parsed = @viz.parse_events(events_text)
  let (system_prompt, header_present) = match fields.get("header") {
    Some(Object(header)) =>
      (
        match header.get("system_prompt") {
          Some(String(prompt)) => prompt
          _ => ""
        },
        true,
      )
    _ => ("", false)
  }
  Loaded(parsed, system_prompt, header_present)
}
