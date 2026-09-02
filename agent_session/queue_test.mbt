///|
test "queue events reconstruct current prompts without entering model history" {
  let session = @agent_session.Session(
      SessionId("queued"),
      system_prompt="system",
    )
    .append(Queue(Added(id="q1", content="first")))
    .append(Queue(Added(id="q2", content="second")))
    .append(Queue(Edited(id="q1", content="first edited")))
    .append(Queue(Withdrawn(id="q2")))
  assert_eq(session.queued_inputs(), [{ id: "q1", content: "first edited", }])
  let messages = session.chat_messages()
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].content, "system")
}

///|
test "queue events round-trip their durable JSON shape" {
  let session = @agent_session.Session(
    SessionId("queued"),
    system_prompt="system",
  ).append(Queue(Added(id="q1", content="later")))
  let json : Json = @json.to_json(session)
  guard json
    is {
      "events": [
        {
          "item": {
            "kind": String("queue"),
            "payload": {
              "action": String("added"),
              "id": String("q1"),
              "content": String("later"),
              ..
            },
            ..
          },
          ..
        },
      ],
      ..
    } else {
    fail("queue event did not use the durable queue shape")
  }
  let decoded : @agent_session.Session = @json.from_json(json)
  assert_eq(decoded.queued_inputs(), [{ id: "q1", content: "later", }])
}
