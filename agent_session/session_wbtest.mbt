///|
test "session constructor recovers highest sequence from unordered events" {
  let events = @vector.from_array([
    SessionEvent(sequence=3, item=User(UserMessage("third"))),
    SessionEvent(sequence=1, item=User(UserMessage("first"))),
    SessionEvent(sequence=2, item=User(UserMessage("second"))),
  ])
  let session = Session(SessionId("unordered"), system_prompt="system", events~)
  assert_eq(session.last_sequence(), 3)
  assert_eq(session.next_sequence(), 4)
}
