///|
test "agent start preserves all engine settings" {
  let payload : @protocol.StartPayload = @json.from_json({
    "task": "inspect",
    "submission_id": "submission-1",
    "model": "deepseek-v4-pro",
    "thinking": "max",
    "max_steps": 42,
    "session": "session-1",
    "workspace": "/work/project",
    "future_field": true,
  })
  assert_eq(payload.thinking, Some(ThinkingMax))
  @debug.assert_eq(payload.to_json(), {
    "task": "inspect",
    "submission_id": "submission-1",
    "model": "deepseek-v4-pro",
    "thinking": "max",
    "max_steps": 42,
    "session": "session-1",
    "workspace": "/work/project",
  })
}

///|
test "OpenSeek thinking values round-trip through their closed codec" {
  let off : @protocol.OpenSeekThinking = @json.from_json(Json::string("no"))
  let high : @protocol.OpenSeekThinking = @json.from_json(Json::string("high"))
  let max : @protocol.OpenSeekThinking = @json.from_json(Json::string("max"))
  assert_eq(off, ThinkingOff)
  assert_eq(high, ThinkingHigh)
  assert_eq(max, ThinkingMax)
  @debug.assert_eq(off.to_json(), Json::string("no"))
  @debug.assert_eq(high.to_json(), Json::string("high"))
  @debug.assert_eq(max.to_json(), Json::string("max"))
}

///|
test "agent payload optional fields accept null and encode absence by omission" {
  let compact : @protocol.CompactPayload = @json.from_json({
    "session": "session-1",
    "model": null,
    "thinking": null,
    "max_steps": null,
    "workspace": null,
  })
  @debug.assert_eq(compact.to_json(), { "session": "session-1" })
  let goal : @protocol.GoalPayload = @json.from_json({
    "session": "session-1",
    "text": null,
    "auto": null,
  })
  @debug.assert_eq(goal.to_json(), { "session": "session-1" })
}

///|
test "agent payload codecs reject malformed known and missing required fields" {
  let malformed_thinking : @protocol.StartPayload? = Some(
    @json.from_json({ "task": "inspect", "session": "session-1", "thinking": 7 }),
  ) catch {
    _ => None
  }
  assert_true(malformed_thinking is None)
  let malformed_auto : @protocol.GoalPayload? = Some(
    @json.from_json({ "session": "session-1", "auto": "yes" }),
  ) catch {
    _ => None
  }
  assert_true(malformed_auto is None)
  let missing_session : @protocol.CompactPayload? = Some(
    @json.from_json({ "thinking": "high" }),
  ) catch {
    _ => None
  }
  assert_true(missing_session is None)
}

///|
test "agent payload codecs reject unsupported thinking values uniformly" {
  let start : @protocol.StartPayload? = Some(
    @json.from_json({
      "task": "inspect",
      "session": "session-1",
      "thinking": "invalid",
    }),
  ) catch {
    _ => None
  }
  assert_true(start is None)
  let compact : @protocol.CompactPayload? = Some(
    @json.from_json({ "session": "session-1", "thinking": "invalid" }),
  ) catch {
    _ => None
  }
  assert_true(compact is None)
  let goal : @protocol.GoalPayload? = Some(
    @json.from_json({ "session": "session-1", "thinking": "invalid" }),
  ) catch {
    _ => None
  }
  assert_true(goal is None)
  let padded : @protocol.StartPayload? = Some(
    @json.from_json({
      "task": "inspect",
      "session": "session-1",
      "thinking": " high ",
    }),
  ) catch {
    _ => None
  }
  assert_true(padded is None)
}
