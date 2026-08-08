///|
test "unknown session items preserve their complete wire object" {
  let raw : Json = {
    "kind": "future_item",
    "payload": { "value": 42 },
    "future_field": true,
  }
  let item : @protocol.SessionItem = @json.from_json(raw)
  guard item is Unknown(preserved) else {
    fail("expected an unknown session item")
  }
  assert_false(item.is_terminal())
  @debug.assert_eq(preserved, raw)
  @debug.assert_eq(item.to_json(), raw)
}

///|
test "new payload shapes fall back to a raw session item" {
  let raw : Json = {
    "kind": "terminal",
    "payload": { "kind": "future_terminal", "message": "later" },
  }
  let item : @protocol.SessionItem = @json.from_json(raw)
  guard item is UnknownTerminal(preserved) else {
    fail("expected a future terminal boundary to remain raw")
  }
  assert_true(item.is_terminal())
  @debug.assert_eq(preserved, raw)
  @debug.assert_eq(item.to_json(), raw)
  let missing_payload : Json = { "kind": "terminal", "future_field": true }
  let missing_item : @protocol.SessionItem = @json.from_json(missing_payload)
  guard missing_item is UnknownTerminal(preserved) else {
    fail("expected a malformed terminal boundary to remain raw")
  }
  assert_true(missing_item.is_terminal())
  @debug.assert_eq(preserved, missing_payload)
}

///|
test "Git original-file replies round-trip through their manual codec" {
  let replies : Array[@protocol.GitOriginalFileReply] = [
    Missing,
    BinaryOriginal,
    OversizedOriginal,
    OriginalContent("fn main { println(\"hi\") }"),
  ]
  for reply in replies {
    let decoded : @protocol.GitOriginalFileReply = @json.from_json(
      reply.to_json(),
    )
    @debug.assert_eq(decoded, reply)
  }
}

///|
test "Git changes replies preserve HEAD identity and accept legacy omission" {
  let reply : @protocol.GitChangesReply = {
    repository: true,
    head: Some("0123456789abcdef"),
    changes: [],
  }
  let decoded : @protocol.GitChangesReply = @json.from_json(reply.to_json())
  @debug.assert_eq(decoded, reply)
  let legacy : @protocol.GitChangesReply = @json.from_json({
    "repository": true,
    "changes": [],
  })
  @debug.assert_eq(legacy.head, None)
}

///|
test "Git original-file payloads pin a revision and accept legacy omission" {
  let payload : @protocol.GitOriginalFilePayload = {
    session: "session",
    workspace: Some("/worktree"),
    path: "src/main.mbt",
    revision: Some("0123456789abcdef"),
  }
  let decoded : @protocol.GitOriginalFilePayload = @json.from_json(
    payload.to_json(),
  )
  @debug.assert_eq(decoded, payload)
  let legacy : @protocol.GitOriginalFilePayload = @json.from_json({
    "session": "session",
    "workspace": "/worktree",
    "path": "src/main.mbt",
  })
  @debug.assert_eq(legacy.revision, None)
}
