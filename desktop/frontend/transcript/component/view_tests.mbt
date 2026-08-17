///|
fn tool_item(
  name : String,
  is_error? : Bool = false,
  brief? : String,
) -> @transcript.TranscriptItem {
  {
    kind: Tool(
      call_id="",
      name~,
      arguments=None,
      has_result=true,
      is_error~,
      brief~,
    ),
    content: "output",
    ts: None,
    sequence: None,
  }
}

///|
test "capitalize is Unicode-safe on a non-BMP first char" {
  inspect(capitalize("hello world"), content="Hello world")
  // 🎉 = U+1F389, a surrogate pair. The old text[1:] sliced into it — corrupt
  // on native, a panic on js. It must survive whole with the remainder intact.
  inspect(capitalize("🎉 done"), content="🎉 done")
  inspect(capitalize(""), content="")
}

///|
test "the transcript's identity attributes carry their wire forms" {
  // `transcript_view` publishes these as `data-transcript-*` on the section,
  // and the component's own subscription reads them back on mutation. The
  // markup is browser-only now, so what is pinned here is the spelling both
  // sides agree on.
  guard @resource.of_path(
      @interop.ChannelId::Remote("relay-a"),
      "/work/project",
    )
    is Some(root) else {
    fail("expected a remote transcript root")
  }
  assert_eq(
    @interop.ChannelId::Remote("relay-a").uri_authority(),
    "remote.relay-a",
  )
  assert_eq(@interop.ChannelId::Local.uri_authority(), "local")
  assert_eq(root.to_string(), "openseek://remote.relay-a/work/project")
}

///|
test "transcript stream children use stable typed keys in display order" {
  let first_tool : @transcript.TranscriptItem = {
    kind: Tool(
      call_id="c1",
      name="shell",
      arguments=None,
      has_result=true,
      is_error=false,
      brief=Some("moon check"),
    ),
    content: "output",
    ts: None,
    sequence: Some(43),
  }
  let input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=1,
    items=[
      {
        item: { kind: User, content: "question", ts: None, sequence: Some(41) },
        identity: "s41\u{0}o0",
      },
      { item: first_tool, identity: "s43\u{0}o0" },
    ],
    streaming_response="partial answer",
    streaming_identity="r7",
    subruns=[
      {
        id: "desktop-abc-sr-1",
        kind: "agent",
        label: "inspect tests",
        steps: 1,
        activity: "reading",
        run: Some("r7"),
      },
    ],
  )
  let renderer : TranscriptRenderer = {
    input,
    on_open: _ => @cmd.none,
    on_jump: _ => @cmd.none,
  }
  let keys = renderer.stream_children().to_array().map(pair => pair.0)
  assert_eq(keys, [
    "row\u{0}s41\u{0}o0", "rule\u{0}s41\u{0}o0", "activity\u{0}after\u{0}s41\u{0}o0",
    "streaming\u{0}r7", "subrun\u{0}r7\u{0}desktop-abc-sr-1",
  ])
  // A newly discovered activity row extends the same card; it does not change
  // the card key and therefore does not replace its browser-owned disclosure.
  let extended = {
    ..input,
    items: [
      input.items[0],
      {
        item: {
          kind: Reasoning,
          content: "thinking",
          ts: None,
          sequence: Some(42),
        },
        identity: "s42\u{0}o0",
      },
      input.items[1],
    ],
  }
  let extended_renderer = { ..renderer, input: extended }
  let extended_keys = extended_renderer
    .stream_children()
    .to_array()
    .map(pair => pair.0)
  assert_eq(extended_keys, keys)
}

///|
test "transcript stream section key scopes equal session ids by channel" {
  let local_input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=0,
    items=[],
    streaming_response="",
    streaming_identity="idle",
    subruns=[],
  )
  let remote = {
    ..local_input,
    focused: @interop.ChannelId::Remote("device-a"),
  }
  assert_eq(
    TranscriptSectionKey::stream(local_input).wire(),
    "stream\u{0}openseek\u{0}local\u{0}desktop-test",
  )
  assert_eq(
    TranscriptSectionKey::stream(remote).wire(),
    "stream\u{0}openseek\u{0}remote.device-a\u{0}desktop-test",
  )
}

///|
test "a tool group's summary recognizes every cmd/openseek built-in" {
  inspect(tool_group_summary([tool_item("read")]), content="Read 1 file")
  inspect(
    tool_group_summary([
      tool_item("read"),
      tool_item("read"),
      tool_item("edit"),
      tool_item("multi_edit"),
      tool_item("write"),
      tool_item("remove"),
      tool_item("shell"),
      tool_item("moon_cmd"),
      tool_item("run_moonbit"),
      tool_item("shell_output"),
      tool_item("shell_stop"),
      tool_item("plan"),
      tool_item("goal"),
      tool_item("finish"),
      tool_item("moon_check compiling"),
      tool_item("mystery"),
    ]),
    content="Read 2 files, wrote 1 file, edited 2 files, removed 1 file, ran 3 commands, checked 1 background job, stopped 1 background job, 1 plan update, 1 goal update, finished, 1 check update, 1 tool call",
  )
  inspect(
    tool_group_summary([
      tool_item("remove"),
      tool_item("remove"),
      tool_item("shell_output"),
      tool_item("shell_output"),
      tool_item("shell_stop"),
      tool_item("shell_stop"),
      tool_item("plan"),
      tool_item("plan"),
      tool_item("goal"),
      tool_item("goal"),
      tool_item("finish"),
      tool_item("finish"),
    ]),
    content="Removed 2 files, checked 2 background jobs, stopped 2 background jobs, 2 plan updates, 2 goal updates, 2 finish calls",
  )
  inspect(
    tool_group_summary([tool_item("shell", is_error=true)]),
    content="Ran 1 command",
  )
}

///|
test "tool activity summaries promote recorded briefs" {
  inspect(
    tool_activity_summary([tool_item("shell", brief="moon test → exit 1")]),
    content="Moon test → exit 1",
  )
  inspect(
    tool_activity_summary([
      tool_item("read", brief="read moon.mod"),
      tool_item("edit", brief="edited view.mbt:42"),
      tool_item("shell", brief="moon test"),
      tool_item("shell"),
    ]),
    content="Read moon.mod · edited view.mbt:42 · +2 more",
  )
  // Older logs and pending calls have no result brief yet.
  inspect(tool_activity_summary([tool_item("shell")]), content="Ran 1 command")
}

///|
test "a completed singleton tool is promoted out of its nested disclosure" {
  // One successful tool with a brief: the card's own summary already names
  // it, so the tool is rendered without repeating that label.
  assert_true(flatten_tool_activity([tool_item("shell", brief="moon test")]))
  // A mixed activity keeps the card, but hands its only successful tool up so
  // the body shows the arguments/output directly.
  let mixed : Array[@transcript.TranscriptItem] = [
    { kind: Reasoning, content: "checking the diff", ts: None, sequence: None },
    tool_item("shell", brief="moon fmt · git diff"),
  ]
  assert_false(flatten_tool_activity(mixed))
  assert_true(inline_singleton_tool(mixed) is Some(_))
  // Failed and plan calls keep the ordinary tool card: their badge and
  // progress affordances belong to it.
  assert_true(
    inline_singleton_tool([
      { kind: Reasoning, content: "thinking", ts: None, sequence: None },
      tool_item("shell", is_error=true),
    ])
    is None,
  )
  // Two tools have no singleton to promote, and a tool-only run never had a
  // nested disclosure to begin with.
  assert_true(
    inline_singleton_tool([
      { kind: Reasoning, content: "thinking", ts: None, sequence: None },
      tool_item("read"),
      tool_item("edit"),
    ])
    is None,
  )
  assert_true(inline_singleton_tool([tool_item("read")]) is None)
}

///|
test "the turn rule dates itself only from a real stamp" {
  // Locale and time zone are the viewer's, so the label's exact text is not
  // asserted — only that a stamped turn gets one and an unstamped turn does
  // not. A zero stamp is what old stores wrote for "no time recorded".
  assert_true(clock_label(1781144351123).contains(":"))
  assert_eq(clock_label(0), "")
  assert_eq(clock_label(-1), "")
}

///|
test "a plan call is drawn as its checklist unless the tool rejected it" {
  // The row asks `@plan.classify` which rendering a recorded call gets: an
  // applied or still-pending call shows the checklist it recorded, while a
  // rejected one keeps the raw payload the model actually sent.
  let arguments = "{\"steps\":[{\"title\":\"fix the parser\",\"status\":\"in_progress\"},{\"title\":\"run moon test\",\"status\":\"pending\"}]}"
  let call = (is_error, has_result) => {
    @plan.classify({
      kind: Tool(
        call_id="c1",
        name="plan",
        arguments=Some(arguments),
        has_result~,
        is_error~,
        brief=None,
      ),
      content: "",
      ts: None,
      sequence: None,
    })
  }
  assert_true(call(false, true) is Some(Applied(_)))
  assert_true(call(false, false) is Some(Pending(_)))
  assert_true(call(true, true) is Some(Rejected))
}

///|
test "tool output truncation keeps the head and tail around a skip marker" {
  let short = "a\nb\nc"
  inspect(truncate_output(short), content="a\nb\nc")
  let lines = [ for index in 0..<200 => "line \{index}" ]
  let clamped = [..truncate_output(lines.join("\n")).split("\n")]
  inspect(clamped.length(), content="101")
  inspect(clamped[0], content="line 0")
  inspect(clamped[59], content="line 59")
  inspect(clamped[60], content="⋯ 100 lines skipped ⋯")
  inspect(clamped[61], content="line 160")
  inspect(clamped[100], content="line 199")
  let one_line = "x".repeat(30_000)
  let bounded = truncate_output(one_line)
  assert_true(bounded.has_prefix("x".repeat(12_000)))
  assert_true(bounded.has_suffix("x".repeat(8_000)))
  assert_true(bounded.contains("10000 UTF-16 code units skipped"))
  // A tool row clamps before it parses, so even a whole-file argument stays
  // well under the payload it was built from.
  assert_true(bounded.length() < 25_000)
}
