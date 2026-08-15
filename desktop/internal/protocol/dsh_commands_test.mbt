///|
test "dsh command envelopes preserve nested versioned JSON" {
  let request : @protocol.DshRequestPayload = @json.from_json({
    "method": "session.prompt",
    "payload": { "content": null },
  })
  assert_eq(request.method_, "session.prompt")
  @debug.assert_eq(request.to_json(), {
    "method": "session.prompt",
    "payload": { "content": null },
  })
  let response : @protocol.DshRespondPayload = @json.from_json({
    "message": { "type": "client-response", "result": { "ok": true } },
  })
  @debug.assert_eq(response.to_json(), {
    "message": { "type": "client-response", "result": { "ok": true } },
  })
  let reply : @protocol.DshValueReply = @json.from_json({ "value": null })
  assert_true(reply.value is Null)
}

///|
test "dsh command envelopes reject missing malformed and unknown fields" {
  let missing = try {
    let _ : @protocol.DshRequestPayload = @json.from_json({
      "method": "session.list",
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(missing)
  let malformed = try {
    let _ : @protocol.DshRequestPayload = @json.from_json({
      "method": null,
      "payload": {},
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(malformed)
  let unknown = try {
    let _ : @protocol.DshValueReply = @json.from_json({
      "value": {},
      "future": true,
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(unknown)
  let no_args = try {
    let _ : @protocol.DshEmptyPayload = @json.from_json({ "extra": true })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(no_args)
}
