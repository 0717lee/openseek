///|
fn render_human_events(
  events : Array[@protocol.Event],
  suppress_events? : Bool = false,
) -> String {
  let renderer = HumanRunRenderer(suppress_events~)
  let out = StringBuilder()
  for event in events {
    out <+ "\{renderer.render(event)}"
  }
  out.to_string()
}

///|
test "human run output streams the answer once and reports aggregate usage" {
  let usage : @protocol.Usage = {
    prompt_tokens: 10,
    completion_tokens: 2,
    total_tokens: 12,
    prompt_cache_hit_tokens: 0,
    prompt_cache_miss_tokens: 10,
  }
  assert_eq(
    render_human_events([
      AgentStep(step=1),
      AssistantDelta(content="Hel"),
      AssistantDelta(content="lo"),
      AssistantMessage(content="Hello"),
      Usage(usage~),
      AgentFinished(answer="Hello"),
    ]),
    "… Thinking (step 1)\nHello\n✓ Finished · 1 step · 10 input / 2 output tokens\n",
  )
}

///|
test "human run output reduces tools and terminal events to compact lines" {
  assert_eq(
    render_human_events([
      AgentStep(step=1),
      ToolResult(
        tool_call_id="call_1",
        tool_name="shell",
        is_error=false,
        content="long raw output",
        brief=Some("moon test passed\n42 tests"),
      ),
      AgentStep(step=2),
      ToolCallDecodeError(
        tool_call_id="call_2",
        tool_name="edit",
        error="missing path",
      ),
      AgentFinished(answer="Done."),
    ]),
    "… Thinking (step 1)\n✓ shell — moon test passed 42 tests\n… Thinking (step 2)\n✗ edit — could not decode call: missing path\nDone.\n✓ Finished · 2 steps\n",
  )
}

///|
test "human run output includes usage on failed terminal status" {
  let usage : @protocol.Usage = {
    prompt_tokens: 8,
    completion_tokens: 3,
    total_tokens: 11,
    prompt_cache_hit_tokens: 0,
    prompt_cache_miss_tokens: 8,
  }
  assert_eq(
    render_human_events([
      AgentStep(step=1),
      Usage(usage~),
      TurnFailed(error="provider unavailable"),
    ]),
    "… Thinking (step 1)\n✗ Turn failed: provider unavailable · 1 step · 8 input / 3 output tokens\n",
  )
}

///|
test "human run output gives unsuccessful subruns non-success markers" {
  assert_eq(
    render_human_events([
      SubrunFinished(
        id="captured",
        status="captured",
        steps=1,
        prompt_tokens=2,
        completion_tokens=3,
      ),
      SubrunFinished(
        id="yield",
        status="context_yield",
        steps=2,
        prompt_tokens=4,
        completion_tokens=5,
      ),
      SubrunFinished(
        id="failed",
        status="failed",
        steps=3,
        prompt_tokens=6,
        completion_tokens=7,
      ),
      AgentFinished(answer="Done."),
    ]),
    "✓ Subrun captured · 1 step(s)\n⚠ Subrun context_yield · 2 step(s)\n✗ Subrun failed · 3 step(s)\nDone.\n✓ Finished · 0 steps · 12 input / 15 output tokens\n",
  )
}

///|
test "human run output can close a partial delta before a runtime failure" {
  let renderer = HumanRunRenderer()
  assert_eq(
    renderer.render(AssistantDelta(content="partial answer")),
    "partial answer",
  )
  assert_eq(renderer.break_line(), "\n")
  assert_eq(renderer.break_line(), "")
}

///|
test "human run output strips terminal controls and caps event details" {
  assert_eq(
    human_content("a\u{1b}[31mred\u{7}\nnext\tcell"),
    "a[31mred\nnext\tcell",
  )
  assert_eq(human_brief("  first\n\tsecond  "), "first second")
  assert_eq(human_brief("abcdef", limit=3), "abc…")
}

///|
test "human fleet output suppresses attempt events but preserves diagnostics" {
  assert_eq(
    render_human_events(
      [
        FleetStarted(runs=2, task="task"),
        AgentStep(step=1),
        AssistantDelta(content="interleaved"),
        AgentFinished(answer="done"),
        McpConfigIgnored(reason="fleet mode does not support MCP servers"),
      ],
      suppress_events=true,
    ),
    "⚠ MCP ignored: fleet mode does not support MCP servers\n",
  )
}

///|
test "run output format defaults to human and accepts explicit jsonl" {
  let human = run_matches(argv=["task"], env=Map([]))
  assert_true(run_output_format(human) is Human)
  let jsonl = run_matches(argv=["--format", "jsonl", "task"], env=Map([]))
  assert_true(run_output_format(jsonl) is Jsonl)
  let jsonl_env = run_matches(argv=["task"], env={
    "OPENSEEK_RUN_FORMAT": "jsonl",
  })
  assert_true(run_output_format(jsonl_env) is Jsonl)
  let invalid = run_matches(argv=["--format", "xml", "task"], env=Map([]))
  let _ = run_output_format(invalid) catch {
    error => {
      assert_true(
        "\{error}".contains(
          "unknown run output format: xml; expected human or jsonl",
        ),
      )
      return
    }
  }
  fail("invalid run output format accepted")
}

///|
test "format is a run-only option" {
  let _ = root_command().parse(argv=["serve", "--format", "human"], env=Map([])) catch {
    error => {
      assert_true("\{error}".contains("unexpected argument '--format' found"))
      return
    }
  }
  fail("serve accepted run-only --format")
}
