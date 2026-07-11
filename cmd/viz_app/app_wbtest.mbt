///|
test "parse_load lifts the system prompt from the header line" {
  let text =
    #|{"found":true,"events":"{\"version\":1,\"id\":\"demo\",\"system_prompt\":\"SYS\"}\n{\"sequence\":1,\"ts\":0,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\n","events_bytes":77}
  guard parse_load(text)
    is Loaded(parsed, system_prompt, header_present, log_bytes) else {
    fail("expected Loaded")
  }
  inspect(parsed.events.length(), content="1")
  inspect(system_prompt, content="SYS")
  inspect(header_present, content="true")
  inspect(log_bytes, content="77")
}

///|
test "parse_load treats a header-less file as events-only" {
  let text =
    #|{"found":true,"events":""}
  guard parse_load(text) is Loaded(_, system_prompt, header_present, log_bytes) else {
    fail("expected Loaded")
  }
  inspect(system_prompt, content="")
  inspect(header_present, content="false")
  inspect(log_bytes, content="0")
}

///|
fn parsed_log(session : @agent_session.Session) -> @session_log.ParsedLog {
  {
    header: None,
    events: [
      for event in session.events() => event
    ],
    errors: [],
    partial_tail: false,
  }
}

///|
test "session metadata counts steps and total runtime" {
  let text =
    #|{"found":true,"events":"{\"sequence\":1,\"ts\":100000,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"hi\"}}}\n{\"sequence\":2,\"ts\":101500,\"item\":{\"kind\":\"assistant\",\"payload\":{\"content\":\"\",\"tool_calls\":[]}}}\n{\"sequence\":3,\"ts\":170300,\"item\":{\"kind\":\"terminal\",\"payload\":{\"kind\":\"finished\",\"message\":\"done\"}}}\n","events_bytes":307}
  guard parse_load(text) is Loaded(parsed, _, _, log_bytes) else {
    fail("expected Loaded")
  }
  inspect(format_log_size(log_bytes), content="307 B")
  inspect(agent_step_count(parsed), content="1")
  inspect(runtime_label(parsed), content="70.3s")
  inspect(end_time_label(parsed), content="1970-01-01 00:02 UTC")
}

///|
test "session metadata counts terminal final answers as steps" {
  let parsed = parsed_log(
    @agent_session.Session(SessionId("terminal-step"), system_prompt="")
    .append(User(UserMessage("hi")))
    .append(Terminal(Finished("done"))),
  )
  inspect(agent_step_count(parsed), content="1")
}

///|
test "session metadata does not double count finish tool terminals" {
  let parsed = parsed_log(
    @agent_session.Session(SessionId("finish-step"), system_prompt="")
    .append(User(UserMessage("hi")))
    .append(Assistant(AssistantMessage("")))
    .append(
      Tool(
        ToolResult(
          tool_call_id="finish_1",
          tool_name="finish",
          content="finished: done",
        ),
      ),
    )
    .append(Terminal(Finished("done"))),
  )
  inspect(agent_step_count(parsed), content="1")
}

///|
test "absolute time labels format UTC timestamps" {
  inspect(absolute_time_label(0L), content="1970-01-01 00:00 UTC")
  inspect(last_active_label(Some(0L)), content="1970-01-01 00:00 UTC")
  inspect(last_active_label(None), content="")
}

///|
test "log size formats larger byte counts" {
  inspect(format_log_size(554702L), content="541.7 KiB")
  inspect(format_log_size(2097152L), content="2.0 MiB")
}

///|
test "apply_dropped_file switches to local-file mode with the header lifted" {
  let text =
    #|{"version":1,"id":"demo","system_prompt":"SYS"}
    #|{"sequence":1,"ts":0,"item":{"kind":"user","payload":{"content":"hi"}}}
    #|
  let selected = { ..init_model(), selected: Some("0|remote"), loading: true }
  let model = apply_dropped_file(selected, "run.jsonl", 123L, text)
  debug_inspect(model.selected, content="None")
  debug_inspect(model.dropped, content="Some(\"run.jsonl\")")
  inspect(model.system_prompt, content="SYS")
  inspect(model.header_present, content="true")
  inspect(model.log_bytes, content="123")
  inspect(model.loading, content="false")
  guard model.parsed is Some(parsed) else { fail("expected parsed log") }
  inspect(parsed.events.length(), content="1")
}

///|
test "apply_dropped_file tolerates a header-less event log" {
  let text =
    #|{"sequence":1,"ts":0,"item":{"kind":"user","payload":{"content":"hi"}}}
    #|
  let model = apply_dropped_file(init_model(), "bare.jsonl", 75L, text)
  inspect(model.system_prompt, content="")
  inspect(model.header_present, content="false")
  guard model.parsed is Some(parsed) else { fail("expected parsed log") }
  inspect(parsed.events.length(), content="1")
}

///|
test "dropped display id prefers the header identity over the file name" {
  let with_header = @viz.parse_events(
    (
      #|{"version":1,"id":"cli-123","system_prompt":"SYS"}
      #|
    ),
  )
  inspect(dropped_display_id("run.jsonl", with_header), content="cli-123")
  let bare = @viz.parse_events("")
  inspect(dropped_display_id("run.jsonl", bare), content="run.jsonl")
}

///|
test "stale dropped-file reads are discarded" {
  let emit = stub_emit()
  let model = { ..init_model(), drop_ticket: 2 }
  // A read issued before the user moved on carries an old ticket: ignored.
  let (_, unchanged) = update(
    emit,
    DroppedFileRead(1, "old.jsonl", 1L, Ok("")),
    model,
  )
  debug_inspect(unchanged.dropped, content="None")
  // The read matching the current ticket applies.
  let (_, applied) = update(
    emit,
    DroppedFileRead(2, "new.jsonl", 1L, Ok("")),
    model,
  )
  debug_inspect(applied.dropped, content="Some(\"new.jsonl\")")
}

///|
test "a late session list does not clobber the dropped-file status" {
  let emit = stub_emit()
  let dropped = apply_dropped_file(
    init_model(),
    "run.jsonl",
    10L,
    (
      #|{"sequence":1,"ts":0,"item":{"kind":"user","payload":{"content":"hi"}}}
      #|
    ),
  )
  let before = dropped.status
  let (_, listed) = update(emit, SessionsFetched(Ok("[]")), dropped)
  inspect(listed.status == before, content="true")
  inspect(listed.sessions.length(), content="0")
  // Without an active dropped file the list outcome still updates the status.
  let (_, plain) = update(emit, SessionsFetched(Ok("[]")), init_model())
  inspect(plain.status, content="0 session(s)")
}

///|
test "selecting a session invalidates an in-flight dropped-file read" {
  let emit = stub_emit()
  let model = { ..init_model(), drop_ticket: 5 }
  let (_, selected) = update(emit, Select("0|remote"), model)
  inspect(selected.drop_ticket, content="6")
  debug_inspect(selected.selected, content="Some(\"0|remote\")")
  // The read the old drop issued now carries a stale ticket.
  let (_, unchanged) = update(
    emit,
    DroppedFileRead(5, "old.jsonl", 1L, Ok("")),
    selected,
  )
  debug_inspect(unchanged.dropped, content="None")
  debug_inspect(unchanged.selected, content="Some(\"0|remote\")")
}

///|
test "parse_load distinguishes not-found from malformed" {
  guard parse_load("{\"found\":false}") is NotFound else {
    fail("expected NotFound")
  }
  guard parse_load("not json") is Malformed else { fail("expected Malformed") }
  guard parse_load("{\"events\":\"x\"}") is Malformed else {
    fail("expected Malformed when found is missing")
  }
}

///|
test "parse_session_rows reads the listing, skipping malformed rows" {
  let text =
    #|[{"key":"0|a","id":"a","root_label":"app/.openseek","last_active":1,"first_prompt":"hello"},{"first_prompt":"no id"},{"id":"b","root":"lib/.openseek","first_prompt":""}]
  guard parse_session_rows(text) is Some(rows) else { fail("expected Some") }
  inspect(rows.length(), content="2")
  inspect(rows[0].key, content="0|a")
  inspect(rows[0].id, content="a")
  inspect(rows[0].root_label, content="app/.openseek")
  inspect(rows[0].first_prompt, content="hello")
  debug_inspect(rows[0].last_active, content="Some(1)")
  inspect(rows[1].key, content="b")
  inspect(rows[1].id, content="b")
  inspect(rows[1].root_label, content="lib/.openseek")
  debug_inspect(rows[1].last_active, content="None")
}

///|
test "parse_session_rows distinguishes empty list from a non-array body" {
  guard parse_session_rows("[]") is Some(empty) else {
    fail("expected Some([])")
  }
  inspect(empty.length(), content="0")
  guard parse_session_rows("oops 500") is None else {
    fail("expected None for a non-JSON body")
  }
  guard parse_session_rows("{\"error\":\"x\"}") is None else {
    fail("expected None for a non-array body")
  }
}

///|
test "session_url percent-encodes the id" {
  inspect(session_url("0|a b/c"), content="/api/sessions/0%7Ca%20b%2Fc")
}

///|
test "sidebar_groups clusters by container, in listing order, no duplicates" {
  let rows = [
    // Two sibling run workspaces share the /tmp/ab container.
    marker_row("0|a", "run", "/tmp/ab/A-1/.openseek"),
    marker_row("1|b", "run", "/tmp/ab/B-1/.openseek"),
    // Default-scan "./" workspaces stay separate (not merged under ".").
    marker_row("2|c", "c", "./app/.openseek"),
    marker_row("3|d", "d", "./lib/.openseek"),
    marker_row("4|e", "e", "./.openseek"),
  ]
  @debug.debug_inspect(
    sidebar_groups(rows),
    content=(
      #|["/tmp/ab", "app", "lib", ""]
    ),
  )
}

///|
fn marker_row(key : String, id : String, root_label : String) -> SessionRow {
  { key, id, root_label, last_active: None, is_marker: true, first_prompt: "" }
}

///|
fn direct_row(key : String, id : String, root_label : String) -> SessionRow {
  { key, id, root_label, last_active: None, is_marker: false, first_prompt: "" }
}

///|
/// A no-op `Emit` for `update` tests that ignore the emitted commands.
fn stub_emit() -> @cmd.Emit[Msg] {
  Emit(_ => @cmd.none)
}

///|
test "session grouping derives container, row label, and heading" {
  // A nested run workspace (marker store): grouped by container, labelled by
  // workspace name.
  inspect(session_group("/tmp/ab/A-1/.openseek", true), content="/tmp/ab")
  inspect(
    session_row_label("/tmp/ab/A-1/.openseek", "run", true),
    content="A-1",
  )
  inspect(group_display("/tmp/ab"), content="/tmp/ab")
  // A workspace directly under cwd groups by itself, labelled by id — and the
  // default-scan "./" prefix normalizes to the same key as the bare form.
  inspect(session_group("./app/.openseek", true), content="app")
  inspect(session_group("app/.openseek", true), content="app")
  inspect(session_row_label("./app/.openseek", "c", true), content="c")
  // A bare cwd store: the current-directory group, labelled by id.
  inspect(session_group("./.openseek", true), content="")
  inspect(session_group(".openseek", true), content="")
  inspect(session_row_label(".openseek", "cli-1", true), content="cli-1")
  inspect(group_display(""), content="current directory")
  // Nested "./"-prefixed roots cluster by their normalized container.
  inspect(
    session_group("./.repos/toml_run_1/.openseek", true),
    content=".repos",
  )
  inspect(
    session_row_label("./.repos/toml_run_1/.openseek", "run", true),
    content="toml_run_1",
  )
  // A direct store (is_marker=false) is its own group, labelled by id — even a
  // hidden one is NOT stripped, so unrelated direct stores never merge.
  inspect(
    session_group("/tmp/openseek-sessions", false),
    content="/tmp/openseek-sessions",
  )
  inspect(
    session_row_label("/tmp/openseek-sessions", "cli-1", false),
    content="cli-1",
  )
  inspect(
    session_group("/tmp/.my-sessions", false),
    content="/tmp/.my-sessions",
  )
  // A non-hidden marker (e.g. --session-root-name sessions) still groups by
  // container when the server flags it as a marker.
  inspect(session_group("runs/A-1/sessions", true), content="runs")
  inspect(session_row_label("runs/A-1/sessions", "x", true), content="A-1")
}

///|
test "sidebar_groups keeps unrelated direct stores separate" {
  let rows = [
    direct_row("0|a", "a", "/srv/store-a"),
    direct_row("1|b", "b", "/srv/store-b"),
  ]
  @debug.debug_inspect(
    sidebar_groups(rows),
    content=(
      #|["/srv/store-a", "/srv/store-b"]
    ),
  )
}

///|
test "collapsed group helpers toggle and prune stale groups" {
  let rows = [
    marker_row("0|a", "a", "app/.openseek"),
    marker_row("1|b", "b", "lib/.openseek"),
  ]
  let collapsed = toggle_collapsed_root([], "app")
  @debug.debug_inspect(collapsed, content="[\"app\"]")
  let expanded = toggle_collapsed_root(collapsed, "app")
  @debug.debug_inspect(expanded, content="[]")
  @debug.debug_inspect(
    prune_collapsed_roots(["app", "stale"], rows),
    content="[\"app\"]",
  )
}

///|
test "app class tracks sidebar visibility" {
  let visible = { ..init_model(), sidebar_visible: true }
  let hidden = { ..init_model(), sidebar_visible: false }
  inspect(app_class(visible), content="app")
  inspect(app_class(hidden), content="app sidebar-hidden")
}

///|
test "theme values map to the data-theme attribute" {
  inspect(Theme::value(Light), content="light")
  inspect(Theme::value(Dark), content="dark")
  inspect(Theme::value(System), content="system")
  // The viewer follows the OS by default.
  assert_true(init_model().theme == System)
}

///|
test "standalone exports default raw while the live viewer defaults model" {
  assert_true(initial_view_mode(true) == RawLog)
  assert_true(initial_view_mode(false) == ModelView)
  assert_true(init_model().view_mode == ModelView)
}

///|
/// An `s=` session key parsed from the URL hash is honored by the first
/// session listing — in the live viewer and exports alike — and consumed
/// whether or not it matches, so a stale key cannot re-fire on refreshes of
/// the list.
test "the hash session key restores the selection on the first listing" {
  let emit = stub_emit()
  let listing =
    #|[{"key":"k1","id":"s1"},{"key":"k2","id":"s2"}]
  let pending = { ..init_model(), pending_restore_key: Some("k2") }
  let (_, restored) = update(emit, SessionsFetched(Ok(listing)), pending)
  debug_inspect(restored.selected, content="Some(\"k2\")")
  debug_inspect(restored.pending_restore_key, content="None")
  // An unknown key is consumed without selecting anything.
  let stale = { ..init_model(), pending_restore_key: Some("gone") }
  let (_, ignored) = update(emit, SessionsFetched(Ok(listing)), stale)
  debug_inspect(ignored.selected, content="None")
  debug_inspect(ignored.pending_restore_key, content="None")
  // An existing selection is never yanked by a late restore key.
  let busy = {
    ..init_model(),
    pending_restore_key: Some("k2"),
    selected: Some("k1"),
  }
  let (_, kept) = update(emit, SessionsFetched(Ok(listing)), busy)
  debug_inspect(kept.selected, content="Some(\"k1\")")
}

///|
/// The hash's `v=` overrides the standalone/live view-mode defaults on
/// restore; anything else falls through to them.
test "the hash view mode wins over the defaults" {
  assert_true(restored_view_mode("raw", false) == RawLog)
  assert_true(restored_view_mode("model", true) == ModelView)
  assert_true(restored_view_mode("", true) == RawLog)
  assert_true(restored_view_mode("", false) == ModelView)
  assert_true(restored_view_mode("nonsense", false) == ModelView)
  inspect(view_mode_value(RawLog), content="raw")
  inspect(view_mode_value(ModelView), content="model")
}

///|
/// Only a standalone export with exactly one session and an untouched pane
/// auto-opens; a live server list, several sessions, an existing selection,
/// or a dropped file all keep the explicit click.
test "single-session standalone exports auto-open their session" {
  let row = direct_row("k1", "s1", "")
  let other = { ..row, key: "k2", id: "s2" }
  assert_true(should_auto_open(true, [row], selected=None, dropped=None))
  assert_false(should_auto_open(false, [row], selected=None, dropped=None))
  assert_false(
    should_auto_open(true, [row, other], selected=None, dropped=None),
  )
  assert_false(should_auto_open(true, [], selected=None, dropped=None))
  assert_false(should_auto_open(true, [row], selected=Some("k1"), dropped=None))
  assert_false(
    should_auto_open(true, [row], selected=None, dropped=Some("f.jsonl")),
  )
}
