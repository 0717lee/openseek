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
    sequence: Some(42),
  }
  let input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=1,
    items=[
      {
        item: { kind: User, content: "question", ts: None, sequence: Some(41), },
        identity: "s41\u{0}o0",
      },
      { item: first_tool, identity: "s42\u{0}o0", },
    ],
    streaming_response=Some("partial answer"),
    streaming_identity="r7",
  )
  let renderer : TranscriptRenderer = {
    input,
    on_open: _ => @cmd.none,
    on_jump: _ => @cmd.none,
    on_open_session: _ => @cmd.none,
  }
  let keys = renderer.stream_children().to_array().map(pair => pair.0)
  assert_eq(keys, [
    "row\u{0}s41\u{0}o0", "rule\u{0}s41\u{0}o0", "activity\u{0}after\u{0}s41\u{0}o0",
    "streaming\u{0}r7",
  ])
  // A newly discovered row from the same durable Assistant step extends the
  // same card; it does not replace its browser-owned disclosure.
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
      { item: first_tool, identity: "s42\u{0}o1", },
    ],
  }
  let extended_renderer = { ..renderer, input: extended, }
  let extended_keys = extended_renderer
    .stream_children()
    .to_array()
    .map(pair => pair.0)
  assert_eq(extended_keys, keys)
}

///|
#warnings("-alert_unstable")
test "durable assistant sequences render as separate foldable steps" {
  let user : VisibleRow = {
    item: { kind: User, content: "question", ts: None, sequence: Some(1), },
    identity: "s1\u{0}o0",
  }
  let first_reasoning : VisibleRow = {
    item: {
      kind: Reasoning,
      content: "first thought",
      ts: None,
      sequence: Some(2),
    },
    identity: "s2\u{0}o0",
  }
  let first_tool : VisibleRow = {
    item: {
      kind: Tool(
        call_id="c1",
        name="read",
        arguments=Some("{}"),
        has_result=true,
        is_error=false,
        brief=Some("read moon.mod"),
      ),
      content: "result",
      ts: None,
      sequence: Some(2),
    },
    identity: "s2\u{0}o2",
  }
  let first_narration : VisibleRow = {
    item: {
      kind: Assistant(is_danger=false),
      content: "I will inspect the project.",
      ts: None,
      sequence: Some(2),
    },
    identity: "s2\u{0}o1",
  }
  let second_reasoning : VisibleRow = {
    item: {
      kind: Reasoning,
      content: "second thought",
      ts: None,
      sequence: Some(4),
    },
    identity: "s4\u{0}o0",
  }
  let goal_notice : VisibleRow = {
    item: {
      kind: Tool(
        call_id="",
        name="goal",
        arguments=None,
        has_result=true,
        is_error=false,
        brief=Some("Goal set"),
      ),
      content: "Ship it",
      ts: None,
      sequence: Some(3),
    },
    identity: "s3\u{0}o0",
  }
  let second_tool : VisibleRow = {
    item: {
      kind: Tool(
        call_id="c2",
        name="shell",
        arguments=Some("{}"),
        has_result=true,
        is_error=false,
        brief=Some("run moon check"),
      ),
      content: "ok",
      ts: None,
      sequence: Some(4),
    },
    identity: "s4\u{0}o1",
  }
  let answer : VisibleRow = {
    item: {
      kind: Assistant(is_danger=false),
      content: "done",
      ts: None,
      sequence: Some(4),
    },
    identity: "s4\u{0}o2",
  }
  let input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=1,
    items=[
      user, first_reasoning, first_narration, first_tool, goal_notice, second_reasoning,
      answer, second_tool,
    ],
    streaming_response=None,
    streaming_identity="idle",
  )
  let renderer : TranscriptRenderer = {
    input,
    on_open: _ => @cmd.none,
    on_jump: _ => @cmd.none,
    on_open_session: _ => @cmd.none,
  }
  let children = renderer.stream_children()
  let keys = children.to_array().map(pair => pair.0)
  assert_eq(keys, [
    "row\u{0}s1\u{0}o0", "rule\u{0}s1\u{0}o0", "row\u{0}s2\u{0}o1", "activity\u{0}after\u{0}s1\u{0}o0",
    "activity\u{0}after\u{0}s2\u{0}o1", "row\u{0}s4\u{0}o2", "activity\u{0}after\u{0}s3\u{0}o0",
  ])
}

///|
/// A durable assistant event appends its tool calls after its prose, and the
/// transcript must display them in that order too: narration first, the step's
/// combined activity after it. The activity keeps its key on the pre-step
/// boundary so the settled card still reuses the live disclosure.
#warnings("-alert_unstable")
test "a durable step with prose and tool calls renders its prose first" {
  let user : VisibleRow = {
    item: { kind: User, content: "question", ts: None, sequence: Some(1), },
    identity: "s1\u{0}o0",
  }
  let narration : VisibleRow = {
    item: {
      kind: Assistant(is_danger=false),
      content: "I will inspect the project.",
      ts: None,
      sequence: Some(2),
    },
    identity: "s2\u{0}o0",
  }
  let tool : VisibleRow = {
    item: {
      kind: Tool(
        call_id="c1",
        name="read",
        arguments=Some("{}"),
        has_result=true,
        is_error=false,
        brief=Some("read moon.mod"),
      ),
      content: "result",
      ts: None,
      sequence: Some(2),
    },
    identity: "s2\u{0}o1",
  }
  let input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=1,
    items=[user, narration, tool],
    streaming_response=None,
    streaming_identity="idle",
  )
  let children = (
    {
      input,
      on_open: _ => @cmd.none,
      on_jump: _ => @cmd.none,
      on_open_session: _ => @cmd.none,
    } : TranscriptRenderer).stream_children()
  let keys = children.to_array().map(pair => pair.0)
  assert_eq(keys, [
    "row\u{0}s1\u{0}o0", "rule\u{0}s1\u{0}o0", "row\u{0}s2\u{0}o0", "activity\u{0}after\u{0}s1\u{0}o0",
  ])
}

///|
#warnings("-alert_unstable")
test "live step hands off to its durable assistant card key" {
  let user : VisibleRow = {
    item: { kind: User, content: "question", ts: None, sequence: Some(1), },
    identity: "s1\u{0}o0",
  }
  let first : VisibleRow = {
    item: {
      kind: Tool(
        call_id="c1",
        name="read",
        arguments=Some("{}"),
        has_result=true,
        is_error=false,
        brief=Some("read moon.mod"),
      ),
      content: "result",
      ts: None,
      sequence: Some(2),
    },
    identity: "s2\u{0}o0",
  }
  let live_input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=1,
    items=[user, first],
    streaming_response=None,
    streaming_reasoning="next thought",
    streaming_identity="r7",
  )
  let live_renderer : TranscriptRenderer = {
    input: live_input,
    on_open: _ => @cmd.none,
    on_jump: _ => @cmd.none,
    on_open_session: _ => @cmd.none,
  }
  let live = live_renderer.stream_children()
  let handoff_key = "activity\u{0}after\u{0}s2\u{0}o0"
  assert_true(live.get(handoff_key) is Some(_))

  let settled_input = {
    ..live_input,
    items: [
      user,
      first,
      {
        item: {
          kind: Reasoning,
          content: "next thought",
          ts: None,
          sequence: Some(4),
        },
        identity: "s4\u{0}o0",
      },
      {
        item: {
          kind: Assistant(is_danger=false),
          content: "answer",
          ts: None,
          sequence: Some(4),
        },
        identity: "s4\u{0}o1",
      },
    ],
    streaming_reasoning: None,
  }
  let settled = { ..live_renderer, input: settled_input, }.stream_children()
  assert_true(settled.get(handoff_key) is Some(_))
}

///|
#warnings("-alert_unstable")
test "an ambiguous commit-first prefix keeps live reasoning visible" {
  let rows : Array[VisibleRow] = [
    {
      item: { kind: User, content: "question", ts: None, sequence: Some(1), },
      identity: "s1\u{0}o0",
    },
    {
      item: {
        kind: Reasoning,
        content: "complete thought",
        ts: None,
        sequence: Some(2),
      },
      identity: "s2\u{0}o0",
    },
    {
      item: {
        kind: Assistant(is_danger=false),
        content: "I will inspect it.",
        ts: None,
        sequence: Some(2),
      },
      identity: "s2\u{0}o1",
    },
    {
      item: {
        kind: Tool(
          call_id="c1",
          name="read",
          arguments=Some("{}"),
          has_result=false,
          is_error=false,
          brief=None,
        ),
        content: "",
        ts: None,
        sequence: Some(2),
      },
      identity: "s2\u{0}o2",
    },
    {
      item: {
        kind: Reasoning,
        content: "later thought",
        ts: None,
        sequence: Some(3),
      },
      identity: "s3\u{0}o0",
    },
    {
      item: {
        kind: Assistant(is_danger=false),
        content: "A later step also committed.",
        ts: None,
        sequence: Some(3),
      },
      identity: "s3\u{0}o1",
    },
  ]
  let input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=1,
    items=rows,
    streaming_response=None,
    streaming_reasoning="complete",
    streaming_identity="r7",
  )
  let children = (
    {
      input,
      on_open: _ => @cmd.none,
      on_jump: _ => @cmd.none,
      on_open_session: _ => @cmd.none,
    } : TranscriptRenderer).stream_children()
  let keys = children.to_array().map(pair => pair.0)
  assert_eq(keys, [
    "row\u{0}s1\u{0}o0", "rule\u{0}s1\u{0}o0", "row\u{0}s2\u{0}o1", "activity\u{0}after\u{0}s1\u{0}o0",
    "row\u{0}s3\u{0}o1", "activity\u{0}after\u{0}s2\u{0}o1", "activity\u{0}after\u{0}s3\u{0}o1",
  ])
}

///|
#warnings("-alert_unstable")
test "live reasoning is plain text and keeps the durable activity key" {
  let user : VisibleRow = {
    item: { kind: User, content: "question", ts: None, sequence: Some(1), },
    identity: "s1\u{0}o0",
  }
  let live_input = Input(
    source=OpenSeek,
    focused=@interop.ChannelId::Local,
    active_session="desktop-test",
    root=None,
    submission_generation=1,
    items=[user],
    streaming_response=None,
    streaming_reasoning="*unfinished*\nnext",
    streaming_identity="r7",
  )
  let live_renderer : TranscriptRenderer = {
    input: live_input,
    on_open: _ => @cmd.none,
    on_jump: _ => @cmd.none,
    on_open_session: _ => @cmd.none,
  }
  let live_children = live_renderer.stream_children()
  assert_true(live_children.get("activity\u{0}after\u{0}s1\u{0}o0") is Some(_))

  let complete_renderer = {
    ..live_renderer,
    input: { ..live_input, reasoning_complete: true, },
  }
  assert_true(
    complete_renderer.stream_children().get("activity\u{0}after\u{0}s1\u{0}o0") is Some(_),
  )

  let settled = {
    ..live_input,
    items: [
      user,
      {
        item: {
          kind: Reasoning,
          content: "*unfinished*\nnext",
          ts: None,
          sequence: Some(2),
        },
        identity: "s2\u{0}o0",
      },
      {
        item: {
          kind: Assistant(is_danger=false),
          content: "answer",
          ts: None,
          sequence: Some(2),
        },
        identity: "s2\u{0}o1",
      },
    ],
    streaming_reasoning: None,
  }
  let settled_renderer = { ..live_renderer, input: settled, }
  let settled_children = settled_renderer.stream_children()
  assert_true(
    settled_children.get("activity\u{0}after\u{0}s1\u{0}o0") is Some(_),
  )
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
    streaming_response=None,
    streaming_identity="idle",
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
}
