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

///|
test "dsh notification envelopes type the Desktop-owned wrapper" {
  let status : @protocol.DshStatusNotification = @json.from_json({
    "status": "unavailable",
    "message": "dsh stopped",
  })
  @debug.assert_eq(status.to_json(), {
    "status": "unavailable",
    "message": "dsh stopped",
  })
  let event : @protocol.DshEventNotification = @json.from_json({
    "stream": "mux",
    "message": null,
    "generation": 3,
  })
  assert_true(event.message is Null)
  @debug.assert_eq(event.to_json(), {
    "stream": "mux",
    "message": null,
    "generation": 3,
  })
}

///|
test "dsh notification envelopes reject malformed wrappers" {
  let missing = try {
    let _ : @protocol.DshEventNotification = @json.from_json({
      "stream": "host",
      "message": {},
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(missing)
  let malformed = try {
    let _ : @protocol.DshStatusNotification = @json.from_json({
      "status": "unavailable",
      "message": false,
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(malformed)
  let unknown = try {
    let _ : @protocol.DshEventNotification = @json.from_json({
      "stream": "mux",
      "message": {},
      "generation": 4,
      "future": true,
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(unknown)
}
