///|
/// Which projection of a session to render: the full append-only `RawLog` (every
/// event in file order, grouped into turns) or `ModelView` — exactly the
/// messages `Session::chat_messages` feeds the model, with summaries substituted
/// for the events they cover and dangling tool calls healed.
pub(all) enum ViewMode {
  RawLog
  ModelView
} derive(Eq, Debug)

///|
/// Render a session under the chosen view mode.
pub fn render_session(
  session : @agent_session.Session,
  mode : ViewMode,
) -> @html.Html {
  match mode {
    RawLog => render_raw(session)
    ModelView => render_model(session)
  }
}

///|
/// Banners for anything the parser flagged: decode failures on individual lines
/// and a truncated final record. Returns `@html.nothing` for a clean log so the
/// caller can stack it unconditionally.
pub fn render_notices(parsed : @session_log.ParsedLog) -> @html.Html {
  let notices : Array[@html.Html] = []
  if parsed.partial_tail {
    notices.push(
      @html.div(class="notice notice-warn", [
        @html.text(
          "⚠ trailing partial line ignored (process likely exited mid-append)",
        ),
      ]),
    )
  }
  for error in parsed.errors {
    notices.push(
      @html.div(class="notice notice-error", [
        @html.div(class="notice-head", [
          @html.text(
            "⚠ line \{error.line_number} could not be decoded: \{error.message}",
          ),
        ]),
        @html.pre(class="notice-body", error.content),
      ]),
    )
  }
  if notices.is_empty() {
    @html.nothing
  } else {
    @html.div(class="notices", notices)
  }
}

// ---- raw log view ----------------------------------------------------------

///|
fn render_raw(session : @agent_session.Session) -> @html.Html {
  let turns = group_turns(session.events())
  let blocks : Array[@html.Html] = []
  for index, turn in turns {
    blocks.push(turn_block(index + 1, turn))
  }
  if blocks.is_empty() {
    return empty_state("This session has no events yet.")
  }
  @html.div(class="log raw-log", blocks)
}

///|
/// Split the flat event log into turns. Every turn closes with exactly one
/// `Terminal` event, so a turn runs up to and including the next `Terminal` —
/// keying off terminals rather than `User` events keeps mid-turn steering
/// (extra `User` events the engine appends before the terminal) inside the same
/// turn. A trailing group with no terminal is a turn cut off mid-flight.
fn group_turns(
  events : @vector.Vector[@agent_session.SessionEvent],
) -> Array[Array[@agent_session.SessionEvent]] {
  let turns : Array[Array[@agent_session.SessionEvent]] = []
  let mut current : Array[@agent_session.SessionEvent] = []
  for event in events {
    current.push(event)
    if event.item() is Terminal(_) {
      turns.push(current)
      current = []
    }
  }
  if !current.is_empty() {
    turns.push(current)
  }
  turns
}

///|
fn turn_block(
  number : Int,
  turn : Array[@agent_session.SessionEvent],
) -> @html.Html {
  // Offsets are relative to the turn's first stamped event: for reading a
  // log, "how far into the turn" answers latency questions directly, where
  // absolute wall clock would force mental subtraction (and a timezone).
  let base = turn_base_ms(turn)
  let cards : Array[@html.Html] = [
    for event in turn => event_card(event, time=offset_label(base, event))
  ]
  let label = match turn_duration_label(turn) {
    Some(duration) => "Turn \{number} · \{turn_preview(turn)} · \{duration}"
    None => "Turn \{number} · \{turn_preview(turn)}"
  }
  // Surface failed tools in the turn header so a turn carrying errors is
  // scannable even while its cards are folded or the turn itself is collapsed.
  let summary : Array[@html.Html] = [@html.text(label)]
  let errors = count_turn_tool_errors(turn)
  if errors > 0 {
    summary.push(
      @html.span(
        class="turn-error-badge",
        " · 🚩 \{errors} error\{plural(errors)}",
      ),
    )
  }
  @html.details(open=true, class="turn", [
    @html.summary(class="turn-summary", summary),
    @html.div(class="turn-body", cards),
  ])
}

///|
/// Number of failed tool results in a turn, for the turn header's error badge.
fn count_turn_tool_errors(turn : Array[@agent_session.SessionEvent]) -> Int {
  let mut count = 0
  for event in turn {
    if event.item() is Tool(result) && result.is_error() {
      count += 1
    }
  }
  count
}

///|
/// `""` for one, `"s"` otherwise — for pluralizing a count in a label.
fn plural(n : Int) -> String {
  if n == 1 {
    ""
  } else {
    "s"
  }
}

///|
/// The turn's first wall-clock stamp (unix ms), or 0 when no event carries
/// one (events appended without a clock keep the 0 sentinel).
fn turn_base_ms(turn : Array[@agent_session.SessionEvent]) -> Int64 {
  for event in turn {
    if event.unix_ms() > 0 {
      return event.unix_ms()
    }
  }
  0
}

///|
fn offset_label(base : Int64, event : @agent_session.SessionEvent) -> String {
  if base == 0 || event.unix_ms() == 0 {
    return ""
  }
  "+\{format_span_seconds(event.unix_ms() - base)}"
}

///|
fn turn_duration_label(turn : Array[@agent_session.SessionEvent]) -> String? {
  let base = turn_base_ms(turn)
  guard base > 0 else { return None }
  let mut last = base
  for event in turn {
    if event.unix_ms() > 0 {
      last = event.unix_ms()
    }
  }
  if last > base {
    Some(format_span_seconds(last - base))
  } else {
    None
  }
}

///|
/// A millisecond span as a compact human duration: `3.4s`, `2m 05.1s`.
fn format_span_seconds(span_ms : Int64) -> String {
  let tenths = span_ms / 100
  if tenths < 600 {
    "\{tenths / 10}.\{tenths % 10}s"
  } else {
    let minutes = tenths / 600
    let rest = tenths % 600
    let seconds = rest / 10
    let pad = if seconds < 10 { "0" } else { "" }
    "\{minutes}m \{pad}\{seconds}.\{rest % 10}s"
  }
}

///|
fn turn_preview(turn : Array[@agent_session.SessionEvent]) -> String {
  for event in turn {
    if event.item() is User(message) {
      return truncate(one_line(message.content()), 80)
    }
  }
  "\{turn.length()} events"
}

///|
fn event_card(
  event : @agent_session.SessionEvent,
  time~ : String,
) -> @html.Html {
  let seq = event.sequence()
  match event.item() {
    User(message) =>
      card("user", "User", seq, time~, [text_block(message.content())])
    Assistant(message) => assistant_card(seq, time, message)
    Tool(result) => tool_card(seq, time, result)
    Runtime(notice) =>
      card("runtime", "Runtime notice", seq, time~, [
        text_block(notice.content()),
      ])
    Summary(summary) => summary_card(seq, time, summary)
    Terminal(terminal) => terminal_card(seq, time, terminal)
  }
}

///|
fn assistant_card(
  seq : Int,
  time : String,
  message : @agent_session.AssistantMessage,
) -> @html.Html {
  let body : Array[@html.Html] = []
  if message.reasoning_content() is Some(reasoning) &&
    !reasoning.trim().is_empty() {
    body.push(
      @html.details(class="reasoning", [
        @html.summary("reasoning"),
        text_block(reasoning),
      ]),
    )
  }
  if !message.content().trim().is_empty() {
    body.push(text_block(message.content()))
  }
  let calls = message.tool_calls()
  if !calls.is_empty() {
    let call_views : Array[@html.Html] = [
      for call in calls => tool_call_view(call)
    ]
    body.push(@html.div(class="tool-calls", call_views))
  }
  card("assistant", "Assistant", seq, time~, body)
}

///|
/// A tool call, with its arguments folded away by default: the row shows only
/// the tool name and expands to the full argument JSON on click. Calls with no
/// meaningful arguments render as a plain name (nothing to fold).
fn tool_call_view(call : @deepseek.ToolCall) -> @html.Html {
  let name_row : Array[@html.Html] = [
    @html.text("→ "),
    @html.strong(call.name),
  ]
  let args = pretty_json(call.arguments)
  if is_blank_args(args) {
    return @html.div(class="tool-call", [
      @html.div(class="tool-call-name", name_row),
    ])
  }
  @html.details(class="tool-call", [
    @html.summary(class="tool-call-name", name_row),
    @html.pre(class="tool-call-args", args),
  ])
}

///|
/// Whether a tool call's (pretty-printed) arguments carry nothing worth folding
/// away — empty text or an empty object.
fn is_blank_args(args : String) -> Bool {
  let trimmed = args.trim().to_owned()
  trimmed.is_empty() || trimmed == "{}"
}

///|
/// Tool output is noisy, so fold it behind the label by default. The summary
/// keeps the tool name and, on failure, a red flag — both visible while the card
/// is collapsed — so a failed tool stands out without expanding it.
fn tool_card(
  seq : Int,
  time : String,
  result : @agent_session.ToolResult,
) -> @html.Html {
  let is_error = result.is_error()
  let kind = if is_error { "tool error" } else { "tool" }
  let label = if is_error {
    "Tool error · \{result.tool_name()}"
  } else {
    "Tool result · \{result.tool_name()}"
  }
  let flag = if is_error {
    @html.span(class="tool-flag", "🚩 failed")
  } else {
    @html.nothing
  }
  @html.details(class="card \{kind}", [
    @html.summary(class="card-label", card_head(label, seq, time~, flag~)),
    @html.div(class="card-body", [text_block(result.content())]),
  ])
}

///|
fn summary_card(
  seq : Int,
  time : String,
  summary : @agent_session.SessionSummary,
) -> @html.Html {
  let label = "Summary · covers events \{summary.from_sequence()}..\{summary.to_sequence()}"
  card("summary", label, seq, time~, [text_block(summary.content())])
}

///|
fn terminal_card(
  seq : Int,
  time : String,
  terminal : @agent_session.TurnTerminal,
) -> @html.Html {
  let (kind, message) = match terminal {
    Finished(answer) => ("finished", answer)
    Aborted(reason) => ("aborted", reason)
    Interrupted(reason) => ("interrupted", reason)
    Failed(message) => ("failed", message)
  }
  let body : Array[@html.Html] = [@html.span(class="badge badge-\{kind}", kind)]
  if !message.trim().is_empty() {
    body.push(text_block(message))
  }
  card("terminal", "Turn ended", seq, time~, body)
}

// ---- model projection view -------------------------------------------------

///|
fn render_model(session : @agent_session.Session) -> @html.Html {
  // The projection keys each tool message only by id and drops is_error / tool
  // name, so recover them from the durable events for display (the messages fed
  // to the model are unchanged — this is view-only enrichment).
  let tool_results = tool_results_by_id(session)
  let messages = session.chat_messages()
  let cards : Array[@html.Html] = [
    for message in messages => message_card(message, tool_results)
  ]
  if cards.is_empty() {
    return empty_state("The model projection is empty.")
  }
  @html.div(class="log model-log", cards)
}

///|
/// Index every `ToolResult` event by its `tool_call_id`, so the model view can
/// recover the error flag and tool name that the projection discards.
fn tool_results_by_id(
  session : @agent_session.Session,
) -> Map[String, @agent_session.ToolResult] {
  let map : Map[String, @agent_session.ToolResult] = Map([])
  for event in session.events() {
    if event.item() is Tool(result) {
      map.set(result.tool_call_id(), result)
    }
  }
  map
}

///|
fn message_card(
  message : @deepseek.ChatMessage,
  tool_results : Map[String, @agent_session.ToolResult],
) -> @html.Html {
  match message.role {
    System =>
      @html.section(class="card system", [
        @html.details(open=false, [
          @html.summary(class="card-label", "System prompt"),
          text_block(message.content),
        ]),
      ])
    User => model_card("user", "User", message)
    Assistant => model_card("assistant", "Assistant", message)
    Tool(_) =>
      model_tool_card(message, model_shown_result(message, tool_results))
  }
}

///|
/// The durable `ToolResult` the model view is allowed to surface for a projected
/// tool message: the one looked up by id whose content is exactly what the model
/// was fed. The projection skips results covered by a later summary and heals a
/// dangling call with a synthetic message; in those cases the looked-up result
/// is not what the model saw, so the content guard rejects it (returns `None`)
/// rather than misrepresent the model view. Shared by `model_tool_card` and
/// `rendered_error_count` so the on-screen flags and the error count never drift.
fn model_shown_result(
  message : @deepseek.ChatMessage,
  tool_results : Map[String, @agent_session.ToolResult],
) -> @agent_session.ToolResult? {
  guard message.role is Tool(id) else { return None }
  match tool_results.get(id) {
    Some(result) if result.content() == message.content => Some(result)
    _ => None
  }
}

///|
/// How many tool-error cards `render_session` draws for `mode` — i.e. failed
/// tool results actually shown, so it equals the number of `.card.tool.error`
/// elements on screen. `RawLog` shows every errored `ToolResult`; `ModelView`
/// shows only those the projection emitted and the view trusts (see
/// `model_shown_result`). Used to drive the "find failures" controls.
pub fn rendered_error_count(
  session : @agent_session.Session,
  mode : ViewMode,
) -> Int {
  let mut count = 0
  match mode {
    RawLog =>
      for event in session.events() {
        if event.item() is Tool(result) && result.is_error() {
          count += 1
        }
      }
    ModelView => {
      let tool_results = tool_results_by_id(session)
      for message in session.chat_messages() {
        if model_shown_result(message, tool_results) is Some(result) &&
          result.is_error() {
          count += 1
        }
      }
    }
  }
  count
}

///|
/// Model-view tool result, folded by default like the raw view. `result` is the
/// durable `ToolResult` looked up by id, which lets this recover the tool name
/// and red-flag failures even though the projection drops `is_error`. A non-zero
/// command exit sets `is_error`, so an `exit=1` result is flagged here just as
/// in the raw log.
///
/// `shown` is the durable result the view trusts for this message (see
/// `model_shown_result`) — `None` when the projection healed/compacted it away,
/// in which case the card is plain and unflagged so it never misrepresents what
/// the model saw.
fn model_tool_card(
  message : @deepseek.ChatMessage,
  shown : @agent_session.ToolResult?,
) -> @html.Html {
  let is_error = shown is Some(r) && r.is_error()
  let name = match shown {
    Some(r) => r.tool_name()
    None => ""
  }
  let kind = if is_error { "tool error" } else { "tool" }
  let label = match (is_error, name.is_empty()) {
    (_, true) => "Tool result"
    (true, false) => "Tool error · \{name}"
    (false, false) => "Tool result · \{name}"
  }
  let head : Array[@html.Html] = []
  if is_error {
    head.push(@html.span(class="tool-flag", "🚩 failed"))
  }
  head.push(@html.text(label))
  @html.details(class="card \{kind}", [
    @html.summary(class="card-label", head),
    @html.div(class="card-body", [text_block(message.content)]),
  ])
}

///|
fn model_card(
  kind : String,
  label : String,
  message : @deepseek.ChatMessage,
) -> @html.Html {
  let body : Array[@html.Html] = []
  if message.reasoning_content is Some(reasoning) &&
    !reasoning.trim().is_empty() {
    body.push(
      @html.details(class="reasoning", [
        @html.summary("reasoning"),
        text_block(reasoning),
      ]),
    )
  }
  if !message.content.trim().is_empty() {
    body.push(text_block(message.content))
  }
  if !message.tool_calls.is_empty() {
    let call_views : Array[@html.Html] = [
      for call in message.tool_calls => tool_call_view(call)
    ]
    body.push(@html.div(class="tool-calls", call_views))
  }
  @html.section(class="card \{kind}", [
    @html.div(class="card-label", label),
    @html.div(class="card-body", body),
  ])
}

// ---- shared helpers --------------------------------------------------------

///|
fn card(
  kind : String,
  label : String,
  seq : Int,
  time~ : String,
  body : Array[@html.Html],
) -> @html.Html {
  @html.section(class="card \{kind}", [
    @html.div(class="card-label", card_head(label, seq, time~)),
    @html.div(class="card-body", body),
  ])
}

///|
/// The card header row: a sequence chip, the label, and (when stamped) a
/// relative-time chip. `flag` sits between the sequence and the label so a
/// folded card can still surface a status marker (e.g. a failed-tool flag) in
/// its summary; it defaults to nothing for ordinary cards.
fn card_head(
  label : String,
  seq : Int,
  time~ : String,
  flag? : @html.Html = @html.nothing,
) -> Array[@html.Html] {
  let head : Array[@html.Html] = [
    @html.span(class="card-seq", "#\{seq}"),
    flag,
    @html.text(label),
  ]
  if !time.is_empty() {
    head.push(@html.span(class="card-ts", time))
  }
  head
}

///|
/// A whitespace-preserving text block. Empty content renders an explicit
/// placeholder so a card never collapses to nothing.
fn text_block(content : String) -> @html.Html {
  if content.trim().is_empty() {
    @html.span(class="empty", "(empty)")
  } else {
    @html.pre(class="content", content)
  }
}

///|
fn empty_state(message : String) -> @html.Html {
  @html.div(class="empty-state", [@html.text(message)])
}

///|
/// Pretty-print a tool call's raw argument string when it is valid JSON; fall
/// back to the raw string otherwise, since the model can emit malformed
/// arguments and the viewer should show them as-is.
fn pretty_json(raw : String) -> String {
  @json.parse(raw).stringify(indent=2) catch {
    _ => raw
  }
}

///|
fn one_line(text : String) -> String {
  text.replace_all(old="\n", new=" ").trim().to_owned()
}

///|
/// Keep the first `limit` characters, appending an ellipsis when text is cut.
/// Iterates by character so it never splits a surrogate pair.
fn truncate(text : String, limit : Int) -> String {
  if text.length() <= limit {
    return text
  }
  let kept = StringBuilder()
  let mut count = 0
  for char in text {
    if count >= limit {
      break
    }
    kept <+ "\{char}"
    count += 1
  }
  "\{kept.to_string()}…"
}
