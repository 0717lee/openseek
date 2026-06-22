///|
fn update_event(state : State, event : @event.AgentEvent) -> Array[Cmd] {
  update(state, AgentProgress(run_id=state.run_id, event))
}

///|
fn update_json(state : State, value : Json) -> Array[Cmd] {
  match @event.decode_event(value) {
    Some(event) => update_event(state, event)
    None => []
  }
}

///|
/// Decode one engine event and run it through `update`, appending any resulting
/// transcript items to `items`. Accumulating into a caller-owned array lets a
/// test replay a whole session and snapshot the rendered transcript at the end.
fn append_items(
  state : State,
  value : Json,
  items : Array[@ui.TranscriptItem],
) -> Unit {
  for cmd in update_json(state, value) {
    if cmd is AppendItem(item) {
      items.push(item)
    }
  }
}

///|
fn spans_text(spans : Array[@doc.Span]) -> String {
  @doc.Text::Text(spans).split_lines().map(text => text.text()).join("|")
}

///|
async test "a shell command runs locally and posts its output" {
  let messages = @async.Queue(kind=Unbounded)
  // `echo` is the same on POSIX `sh` and Windows `pwsh`, so the platform shell
  // `@shell.collect_shell_output` picks runs this on either.
  run_shell_command(1, "echo hello", messages)
  // The only message is the local command result: a completed tool item titled
  // with the command, its stdout as a dimmed detail line. Nothing is sent to the
  // engine.
  let item = match messages.get() {
    CommandResult(item, ..) => item
    _ => fail("expected a CommandResult")
  }
  debug_inspect(
    item,
    content=(
      #|ToolCall(
      #|  {
      #|    title: {
      #|      spans: [
      #|        {
      #|          display: {
      #|            text: "$ echo hello",
      #|            units: [
      #|              {
      #|                text: <StringView: "$">,
      #|                width: 1,
      #|                textual_end: TextualPosition(1),
      #|                display_end: DisplayPosition(1),
      #|              },
      #|              {
      #|                text: <StringView: " ">,
      #|                width: 1,
      #|                textual_end: TextualPosition(2),
      #|                display_end: DisplayPosition(2),
      #|              },
      #|              {
      #|                text: <StringView: "e">,
      #|                width: 1,
      #|                textual_end: TextualPosition(3),
      #|                display_end: DisplayPosition(3),
      #|              },
      #|              {
      #|                text: <StringView: "c">,
      #|                width: 1,
      #|                textual_end: TextualPosition(4),
      #|                display_end: DisplayPosition(4),
      #|              },
      #|              {
      #|                text: <StringView: "h">,
      #|                width: 1,
      #|                textual_end: TextualPosition(5),
      #|                display_end: DisplayPosition(5),
      #|              },
      #|              {
      #|                text: <StringView: "o">,
      #|                width: 1,
      #|                textual_end: TextualPosition(6),
      #|                display_end: DisplayPosition(6),
      #|              },
      #|              {
      #|                text: <StringView: " ">,
      #|                width: 1,
      #|                textual_end: TextualPosition(7),
      #|                display_end: DisplayPosition(7),
      #|              },
      #|              {
      #|                text: <StringView: "h">,
      #|                width: 1,
      #|                textual_end: TextualPosition(8),
      #|                display_end: DisplayPosition(8),
      #|              },
      #|              {
      #|                text: <StringView: "e">,
      #|                width: 1,
      #|                textual_end: TextualPosition(9),
      #|                display_end: DisplayPosition(9),
      #|              },
      #|              {
      #|                text: <StringView: "l">,
      #|                width: 1,
      #|                textual_end: TextualPosition(10),
      #|                display_end: DisplayPosition(10),
      #|              },
      #|              {
      #|                text: <StringView: "l">,
      #|                width: 1,
      #|                textual_end: TextualPosition(11),
      #|                display_end: DisplayPosition(11),
      #|              },
      #|              {
      #|                text: <StringView: "o">,
      #|                width: 1,
      #|                textual_end: TextualPosition(12),
      #|                display_end: DisplayPosition(12),
      #|              },
      #|            ],
      #|            width: 12,
      #|            cjk: false,
      #|          },
      #|          style: { foreground: Default, background: Default, underline: false },
      #|        },
      #|      ],
      #|    },
      #|    status: Some(Completed),
      #|    details: [
      #|      {
      #|        spans: [
      #|          {
      #|            display: {
      #|              text: "hello",
      #|              units: [
      #|                {
      #|                  text: <StringView: "h">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(1),
      #|                  display_end: DisplayPosition(1),
      #|                },
      #|                {
      #|                  text: <StringView: "e">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(2),
      #|                  display_end: DisplayPosition(2),
      #|                },
      #|                {
      #|                  text: <StringView: "l">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(3),
      #|                  display_end: DisplayPosition(3),
      #|                },
      #|                {
      #|                  text: <StringView: "l">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(4),
      #|                  display_end: DisplayPosition(4),
      #|                },
      #|                {
      #|                  text: <StringView: "o">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(5),
      #|                  display_end: DisplayPosition(5),
      #|                },
      #|              ],
      #|              width: 5,
      #|              cjk: false,
      #|            },
      #|            style: {
      #|              foreground: Basic(BrightBlack),
      #|              background: Default,
      #|              underline: false,
      #|            },
      #|          },
      #|        ],
      #|      },
      #|    ],
      #|  },
      #|)
    ),
  )
}

///|
test "a runtime_update event surfaces as a ↻ tool-style notice" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  assert_true(state.run is Running(_))
  let items : Array[@ui.TranscriptItem] = []
  // A realistic engine body: the `[moon_check update]` header, the key=value
  // metadata preamble, then the captured watcher output.
  append_items(
    state,
    Json::object({
      "event": "runtime_update",
      "content": "[moon_check update]\nevents=3\nid=moon-check-1\ncwd=.\ncommand=moon check --watch --diagnostic-limit 10\nstatus=running\nseq=3\nWarning: unused variable x\nFinished.",
    }),
    items,
  )
  // The metadata preamble is stripped: the watcher status is lifted out and only
  // the captured diagnostics remain (the `↻` tool-style rendering itself is
  // covered in `tui/core`).
  let view = parse_runtime_update(
    "[moon_check update]\nevents=3\nid=moon-check-1\ncwd=.\ncommand=moon check --watch --diagnostic-limit 10\nstatus=running\nseq=3\nWarning: unused variable x\nFinished.",
  )
  inspect(view.status, content="running")
  inspect(
    view.diagnostics.join("|"),
    content="Warning: unused variable x|Finished.",
  )
  // The event yields exactly one non-terminal `Notice`, and the status bar picks
  // up the watcher state.
  guard items is [Notice(_)] else { fail("expected a single Notice item") }
  assert_eq(state.watcher_status, "running")
  assert_true(state.run is Running(_))

  // A status-less update — the engine's compact "results unchanged"
  // marker — must not blank the live watcher's segment.
  let _ = update(
    state,
    AgentProgress(
      run_id=state.run_id,
      RuntimeUpdate(
        "[moon_check update]\nwatchers re-ran; results unchanged from the previous update",
      ),
    ),
  )
  assert_eq(state.watcher_status, "running")
  // The watcher belongs to the persistent engine, which outlives the turn:
  // the status survives the terminal event and only clears when the engine
  // process itself exits.
  let _ = update(
    state,
    AgentProgress(run_id=state.run_id, AgentFinished("done")),
  )
  assert_true(state.run is Idle)
  assert_eq(state.watcher_status, "running")
  let _ = update(state, EngineExited)
  assert_eq(state.watcher_status, "")
  assert_eq(watcher_segment_text(state.watcher_status), "")
}

///|
test "parse_runtime_update aggregates status across watcher sections" {
  // A single update lists one section per watcher key. When one watcher has
  // stopped but another is still running — and the stopped one is parsed last —
  // the status must be `running`, not the last-seen value, so the status bar
  // does not claim checking is done while a watcher is still active.
  let view = parse_runtime_update(
    "[moon_check update]\nevents=2\nid=a\nstatus=running\nseq=1\nchecking a\n\nid=b\nstatus=stopped\nseq=1\ndone b",
  )
  inspect(view.status, content="running")
  inspect(view.diagnostics.join("|"), content="checking a||done b")

  // With every section stopped, the aggregate falls back to the last status.
  let stopped = parse_runtime_update(
    "[moon_check update]\nevents=2\nid=a\nstatus=stopped\nseq=1\n\nid=b\nstatus=stopped\nseq=1",
  )
  inspect(stopped.status, content="stopped")
}

///|
test "assistant_delta opens a live response item and final message finishes it" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let items : Array[@ui.TranscriptItem] = []
  let first = update_event(state, AssistantDelta("Hel"))
  guard first is [BeginStreamingItem(Response), WriteStreamingItem(spans)] else {
    fail("expected stream begin and write")
  }
  inspect(spans_text(spans), content="Hel")
  assert_true(state.stream_phase is ResponseStreaming)
  let second = update_event(state, AssistantDelta("lo"))
  guard second is [WriteStreamingItem(spans)] else {
    fail("expected another stream write")
  }
  inspect(spans_text(spans), content="lo")
  assert_eq(items.length(), 0)
  assert_true(state.step_response is None)
  let final_message = update_event(state, AssistantMessage("Hello"))
  guard final_message is [FinishStreamingItem] else {
    fail("expected stream finish")
  }
  assert_true(state.stream_phase is ResponseDone)
  assert_true(state.step_response is Some("Hello"))
  for cmd in update_event(state, AgentFinished("Hello")) {
    if cmd is AppendItem(item) {
      items.push(item)
    }
  }
  assert_eq(items.length(), 0)
}

///|
test "assistant_message finishes live stream while tools continue" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let items : Array[@ui.TranscriptItem] = []
  let _ = update_event(state, AssistantDelta("Need tool"))
  assert_true(state.stream_phase is ResponseStreaming)
  let cmds = update_event(state, AssistantMessage("Need tool"))
  guard cmds is [FinishStreamingItem] else { fail("expected stream finish") }
  assert_true(state.run is Running(_))
  assert_true(state.stream_phase is ResponseDone)
  assert_true(state.step_response is Some("Need tool"))
  assert_eq(items.length(), 0)
}

///|
test "agent_finished closes live response stream without duplicating answer" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let _ = update_event(state, AssistantDelta("done"))
  assert_true(state.stream_phase is ResponseStreaming)
  let cmds = update_event(state, AgentFinished("done"))
  guard cmds is [FinishStreamingItem] else {
    fail("expected only stream finish")
  }
  assert_true(state.run is Idle)
  assert_true(state.stream_phase is StreamNotStarted)
}

///|
test "assistant_delta writes raw spans without activity-line truncation" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let long = String::make(300, 'x')
  let cmds = update_event(state, AssistantDelta(long))
  guard cmds is [BeginStreamingItem(Response), WriteStreamingItem(spans)] else {
    fail("expected stream write")
  }
  assert_eq(spans_text(spans).length(), long.length())
}

///|
test "assistant_delta preserves hard newlines for the item writer" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let first = update_event(state, AssistantDelta("fn main {\n"))
  guard first is [BeginStreamingItem(Response), WriteStreamingItem(spans)] else {
    fail("expected stream write")
  }
  inspect(spans_text(spans), content="fn main {|")
  let second = update_event(state, AssistantDelta("  println(1)\n}"))
  guard second is [WriteStreamingItem(spans)] else {
    fail("expected stream write")
  }
  inspect(spans_text(spans), content="  println(1)|}")
}

///|
test "reasoning_delta streams a thought item and final reasoning closes it" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let items : Array[@ui.TranscriptItem] = []
  let start = update_event(state, ReasoningDelta("Let me think"))
  guard start is [BeginStreamingItem(Thought), WriteStreamingItem(spans)] else {
    fail("expected thought stream start")
  }
  inspect(spans_text(spans), content="Let me think")
  assert_true(state.stream_phase is ReasoningStreaming)
  // The full reasoning only closes the streamed thought item. It must not append
  // the old compact `✻ thought` block.
  let finish = update_event(
    state,
    ReasoningMessage("Let me think about names.\nThe user said Hongbo."),
  )
  guard finish is [FinishStreamingItem] else {
    fail("expected thought stream finish")
  }
  assert_true(state.stream_phase is ReasoningDone)
  assert_eq(items.length(), 0)
  // A later blank reasoning message does not append an empty aside.
  for cmd in update_event(state, ReasoningMessage("  ")) {
    if cmd is AppendItem(item) {
      items.push(item)
    }
  }
  assert_eq(items.length(), 0)
}

///|
test "reasoning_message falls back to a thought stream when no deltas arrived" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let cmds = update_event(state, ReasoningMessage("final thought"))
  guard cmds
    is [
      BeginStreamingItem(Thought),
      WriteStreamingItem(spans),
      FinishStreamingItem,
    ] else {
    fail("expected fallback thought stream")
  }
  inspect(spans_text(spans), content="final thought")
  assert_true(state.stream_phase is ReasoningDone)
}

///|
test "late reasoning_message does not open a thought stream over response" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let first = update_event(state, AssistantDelta("answer"))
  guard first is [BeginStreamingItem(Response), WriteStreamingItem(_)] else {
    fail("expected response stream start")
  }
  assert_true(state.stream_phase is ResponseStreaming)
  // Some engines only expose final reasoning after content has already
  // streamed. That final reasoning is too late to preserve thought-before-answer
  // order, so it must not try to open a nested thought writer.
  assert_eq(update_event(state, ReasoningMessage("late thought")).length(), 0)
  assert_true(state.stream_phase is ResponseStreaming)
  let finish = update_event(state, AssistantMessage("answer"))
  guard finish is [FinishStreamingItem] else {
    fail("expected response stream finish")
  }
  assert_true(state.stream_phase is ResponseDone)
}

///|
test "late reasoning_message stays ignored after response is closed" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let _ = update_event(state, AssistantMessage("answer"))
  assert_true(state.stream_phase is ResponseDone)
  assert_eq(update_event(state, ReasoningMessage("late thought")).length(), 0)
  assert_true(state.stream_phase is ResponseDone)
}

///|
test "reasoning stream finishes before response stream starts" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let cmds = update_event(state, ReasoningDelta("Let me think"))
  guard cmds is [BeginStreamingItem(Thought), WriteStreamingItem(_)] else {
    fail("expected thought stream start")
  }
  assert_true(state.stream_phase is ReasoningStreaming)
  // The first content delta finishes the thought stream before opening the
  // response stream, so no compact thought item is inserted in the middle.
  let response = update_event(state, AssistantDelta("Answer"))
  guard response
    is [
      FinishStreamingItem,
      BeginStreamingItem(Response),
      WriteStreamingItem(_),
    ] else {
    fail("expected thought finish then response stream start")
  }
  assert_true(state.stream_phase is ResponseStreaming)
  // The final full reasoning message is ignored because deltas already produced
  // the thought item.
  assert_eq(update_event(state, ReasoningMessage("Let me think")).length(), 0)
  // The committed message closes the response stream.
  let finish = update_event(state, AssistantMessage("Answer"))
  guard finish is [FinishStreamingItem] else { fail("expected stream finish") }
  assert_true(state.stream_phase is ResponseDone)
}

///|
test "run failure closes a live response stream before appending error" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let _ = update_event(state, AssistantDelta("partial"))
  assert_true(state.stream_phase is ResponseStreaming)
  let cmds = update(
    state,
    AgentFailed(run_id=state.run_id, Failure::Failure("boom")),
  )
  guard cmds is [FinishStreamingItem, AppendItem(Error(_))] else {
    fail("expected stream finish before error")
  }
  assert_true(state.stream_phase is StreamNotStarted)
  assert_true(state.run is Idle)
}

///|
test "replaying a recorded engine session renders the transcript" {
  let state = drain_test_state()
  // Submit a task so the agent is running before progress arrives.
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  assert_true(state.run is Running(_))

  // A realistic one-step session: think, report usage, run a tool, finish.
  let items : Array[@ui.TranscriptItem] = []
  append_items(state, Json::object({ "event": "agent_step", "step": 1 }), items)
  append_items(
    state,
    Json::object({
      "event": "assistant_message",
      "content": "Let me check the project.",
    }),
    items,
  )
  append_items(
    state,
    Json::object({
      "event": "usage",
      "prompt_tokens": 100,
      "completion_tokens": 20,
      "cache_hit_tokens": 0,
      "cache_miss_tokens": 100,
    }),
    items,
  )
  append_items(
    state,
    Json::object({
      "event": "tool_result",
      "tool_call_id": "c1",
      "tool_name": "bash",
      "is_error": false,
      "content": "ok",
    }),
    items,
  )
  append_items(
    state,
    Json::object({ "event": "agent_finished", "answer": "all done" }),
    items,
  )

  // The rendered transcript: the assistant message, the tool result, and the
  // final answer. `agent_step` and `usage` update state without emitting items.
  debug_inspect(
    items,
    content=(
      #|[
      #|  Response("Let me check the project."),
      #|  ToolCall(
      #|    {
      #|      title: {
      #|        spans: [
      #|          {
      #|            display: {
      #|              text: "Tool bash",
      #|              units: [
      #|                {
      #|                  text: <StringView: "T">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(1),
      #|                  display_end: DisplayPosition(1),
      #|                },
      #|                {
      #|                  text: <StringView: "o">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(2),
      #|                  display_end: DisplayPosition(2),
      #|                },
      #|                {
      #|                  text: <StringView: "o">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(3),
      #|                  display_end: DisplayPosition(3),
      #|                },
      #|                {
      #|                  text: <StringView: "l">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(4),
      #|                  display_end: DisplayPosition(4),
      #|                },
      #|                {
      #|                  text: <StringView: " ">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(5),
      #|                  display_end: DisplayPosition(5),
      #|                },
      #|                {
      #|                  text: <StringView: "b">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(6),
      #|                  display_end: DisplayPosition(6),
      #|                },
      #|                {
      #|                  text: <StringView: "a">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(7),
      #|                  display_end: DisplayPosition(7),
      #|                },
      #|                {
      #|                  text: <StringView: "s">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(8),
      #|                  display_end: DisplayPosition(8),
      #|                },
      #|                {
      #|                  text: <StringView: "h">,
      #|                  width: 1,
      #|                  textual_end: TextualPosition(9),
      #|                  display_end: DisplayPosition(9),
      #|                },
      #|              ],
      #|              width: 9,
      #|              cjk: false,
      #|            },
      #|            style: { foreground: Default, background: Default, underline: false },
      #|          },
      #|        ],
      #|      },
      #|      status: Some(Completed),
      #|      details: [
      #|        {
      #|          spans: [
      #|            {
      #|              display: {
      #|                text: "ok",
      #|                units: [
      #|                  {
      #|                    text: <StringView: "o">,
      #|                    width: 1,
      #|                    textual_end: TextualPosition(1),
      #|                    display_end: DisplayPosition(1),
      #|                  },
      #|                  {
      #|                    text: <StringView: "k">,
      #|                    width: 1,
      #|                    textual_end: TextualPosition(2),
      #|                    display_end: DisplayPosition(2),
      #|                  },
      #|                ],
      #|                width: 2,
      #|                cjk: false,
      #|              },
      #|              style: {
      #|                foreground: Basic(BrightBlack),
      #|                background: Default,
      #|                underline: false,
      #|              },
      #|            },
      #|          ],
      #|        },
      #|      ],
      #|    },
      #|  ),
      #|  Response("all done"),
      #|]
    ),
  )
  match state.usage {
    Some(usage) => assert_eq(usage.total_tokens, 120)
    None => fail("usage not recorded")
  }
  // The terminal event left the agent idle.
  assert_true(state.run is Idle)
}
