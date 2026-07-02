///|
test "decode a valid plan" {
  debug_inspect(
    @decode.decode({
      "steps": [
        { "title": "read the failing test", "status": "done" },
        { "title": "fix the parser", "status": "active" },
        { "title": "run moon test", "status": "pending" },
      ],
    }),
    content=(
      #|{
      #|  steps: [
      #|    { title: "read the failing test", status: Done },
      #|    { title: "fix the parser", status: Active },
      #|    { title: "run moon test", status: Pending },
      #|  ],
      #|}
    ),
  )
}

///|
test "decode a plan with no active step" {
  debug_inspect(
    @decode.decode({
      "steps": [
        { "title": "step one", "status": "done" },
        { "title": "step two", "status": "done" },
      ],
    }),
    content=(
      #|{
      #|  steps: [
      #|    { title: "step one", status: Done },
      #|    { title: "step two", status: Done },
      #|  ],
      #|}
    ),
  )
}

///|
/// Asserts that decoding `arguments` fails and the error message names the
/// offending field.
fn assert_decode_error(arguments : Json, expected : String) -> Unit raise {
  let _ = @decode.decode(arguments) catch {
    error => {
      let message = "\{error}"
      assert_true(
        message.contains(expected),
        msg="\{message} should contain \{expected}",
      )
      return
    }
  }
  fail("expected decode error")
}

///|
test "decode rejects missing steps" {
  assert_decode_error({}, "arguments.steps to be an array")
}

///|
test "decode rejects non-object arguments" {
  assert_decode_error(Json::null(), "arguments.steps to be an array")
}

///|
test "decode rejects an empty plan" {
  assert_decode_error({ "steps": [] }, "arguments.steps to be non-empty")
}

///|
test "decode rejects more than MAX_STEPS steps" {
  let steps : Array[Json] = [
    for i in 0..<(@decode.MAX_STEPS + 1) => {
      { "title": "step \{i}", "status": "pending" }
    }
  ]
  assert_decode_error({ "steps": steps.to_json() }, "at most 20 steps, got 21")
}

///|
test "decode rejects a non-object step" {
  assert_decode_error(
    { "steps": ["just a string"] },
    "arguments.steps[0] to be an object",
  )
}

///|
test "decode rejects a missing title" {
  assert_decode_error(
    { "steps": [{ "status": "pending" }] },
    "arguments.steps[0].title to be a string",
  )
}

///|
test "decode rejects a blank title" {
  assert_decode_error(
    { "steps": [{ "title": "  ", "status": "pending" }] },
    "arguments.steps[0].title to be non-blank",
  )
}

///|
test "decode rejects a missing status" {
  assert_decode_error(
    { "steps": [{ "title": "step" }] },
    "arguments.steps[0].status to be a string",
  )
}

///|
test "decode rejects an unknown status" {
  assert_decode_error(
    { "steps": [{ "title": "step", "status": "blocked" }] },
    "arguments.steps[0].status to be one of pending|active|done, got \"blocked\"",
  )
}

///|
test "decode rejects two active steps and names the rule" {
  assert_decode_error(
    {
      "steps": [
        { "title": "one", "status": "active" },
        { "title": "two", "status": "active" },
      ],
    },
    "at most one active step",
  )
}
