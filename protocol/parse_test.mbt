///|
/// `parse` against literal lines, with no `emit` in sight.
///
/// These run on every backend the module supports — js, wasm, wasm-gc, native —
/// which is the point of keeping the decoder free of `@xlog`: a client that
/// reads the stream does not have to be a native binary. The round-trip against
/// the real encoder lives in the `emit` package, which is native-only.
fn decode(line : String) -> @openseek_protocol.Event? {
  @openseek_protocol.parse(@json.parse(line) catch { _ => return None })
}

///|
test "decodes a streaming delta" {
  debug_inspect(
    decode(
      (
        #|{"timestamp":"t","level":"INFO","source":"s","event":"assistant_delta","content":"Hel"}
      ),
    ),
    content=(
      #|Some(AssistantDelta(content="Hel"))
    ),
  )
}

///|
/// The envelope is ignored: a reader cares about the event, not about which
/// line of the engine reported it.
test "decodes with the envelope absent" {
  debug_inspect(
    decode(
      (
        #|{"event":"agent_step","step":7}
      ),
    ),
    content=(
      #|Some(AgentStep(step=7))
    ),
  )
}

///|
test "decodes the nested usage payload" {
  debug_inspect(
    decode(
      (
        #|{"event":"usage","usage":{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33,"prompt_cache_hit_tokens":4,"prompt_cache_miss_tokens":7}}
      ),
    ),
    content=(
      #|Some(
      #|  Usage(
      #|    usage={
      #|      prompt_tokens: 11,
      #|      completion_tokens: 22,
      #|      total_tokens: 33,
      #|      prompt_cache_hit_tokens: 4,
      #|      prompt_cache_miss_tokens: 7,
      #|    },
      #|  ),
      #|)
    ),
  )
}

///|
/// A null optional field and an absent one are the same value — the property
/// that let the three `tool_result` call sites converge on one shape.
test "a null optional field reads as absent" {
  debug_inspect(
    decode(
      (
        #|{"event":"tool_result","tool_call_id":"c1","tool_name":"read","is_error":false,"content":"body","brief":null}
      ),
    ),
    content=(
      #|Some(
      #|  ToolResult(
      #|    tool_call_id="c1",
      #|    tool_name="read",
      #|    is_error=false,
      #|    content="body",
      #|    brief=None,
      #|  ),
      #|)
    ),
  )
  debug_inspect(
    decode(
      (
        #|{"event":"tool_result","tool_call_id":"c1","tool_name":"read","is_error":false,"content":"body"}
      ),
    ),
    content=(
      #|Some(
      #|  ToolResult(
      #|    tool_call_id="c1",
      #|    tool_name="read",
      #|    is_error=false,
      #|    content="body",
      #|    brief=None,
      #|  ),
      #|)
    ),
  )
}

///|
/// An engine older than 2026-06-25 (9b2f6c43) emits `steer_applied` with only
/// `content`. The TUI launches whichever `openseek` is on PATH, so that pairing
/// is real, and a reader that dropped those lines would silently lose steers.
/// `kind` therefore defaults instead of being required — the rule every client
/// applied by hand before this package, now written down once and tested.
test "an older engine's steer_applied still decodes" {
  debug_inspect(
    decode(
      (
        #|{"event":"steer_applied","content":"go left"}
      ),
    ),
    content=(
      #|Some(SteerApplied(kind="prompt", content="go left"))
    ),
  )
}

///|
/// A line from a newer engine, or one that is not an event at all, is ignored
/// rather than failing the reader.
test "unknown and malformed lines are ignored" {
  assert_eq(@openseek_protocol.parse(Json::string("not an object")), None)
  assert_eq(@openseek_protocol.parse({ "level": "INFO" }), None)
  assert_eq(@openseek_protocol.parse({ "event": "from_a_newer_engine" }), None)
  // `agent_step` without its required payload.
  assert_eq(@openseek_protocol.parse({ "event": "agent_step" }), None)
  // A fractional `step` is not an Int.
  assert_eq(
    @openseek_protocol.parse({ "event": "agent_step", "step": 1.5 }),
    None,
  )
}
