///|
test "goal status decodes met and continuing" {
  assert_true(@goal.decode_status({ "status": "met" }) is Ok(Met))
  assert_true(
    @goal.decode_status({ "status": "continuing", "remaining": "parser left" })
    is Ok(Continuing("parser left")),
  )
}

///|
test "goal status rejects malformed arguments" {
  guard @goal.decode_status({ "status": "continuing" }) is Err(message) else {
    fail("continuing without remaining accepted")
  }
  assert_true(message.contains("remaining"))
  guard @goal.decode_status({ "status": "continuing", "remaining": "  " })
    is Err(message) else {
    fail("blank remaining accepted")
  }
  assert_true(message.contains("non-blank"))
  guard @goal.decode_status({ "status": "done" }) is Err(message) else {
    fail("unknown status accepted")
  }
  assert_true(message.contains("met"))
  guard @goal.decode_status({ "remaining": "x" }) is Err(message) else {
    fail("missing status accepted")
  }
  assert_true(message.contains("status"))
}

///|
test "goal definition validates through its fallback execute" {
  let definition = @goal.definition()
  assert_eq(definition.name, "goal")
}
