///|
test "decode a valid plan" {
  debug_inspect(
    @decode.decode({
      "steps": [
        { "title": "read the failing test", "status": "completed" },
        { "title": "fix the parser", "status": "in_progress" },
        { "title": "run moon test", "status": "pending" },
      ],
    }),
    content=(
      #|{
      #|  steps: [
      #|    { title: "read the failing test", status: Completed },
      #|    { title: "fix the parser", status: InProgress },
      #|    { title: "run moon test", status: Pending },
      #|  ],
      #|}
    ),
  )
}

///|
test "decode a plan with no in_progress step" {
  debug_inspect(
    @decode.decode({
      "steps": [
        { "title": "step one", "status": "completed" },
        { "title": "step two", "status": "completed" },
      ],
    }),
    content=(
      #|{
      #|  steps: [
      #|    { title: "step one", status: Completed },
      #|    { title: "step two", status: Completed },
      #|  ],
      #|}
    ),
  )
}

///|
test "decode trims surrounding title whitespace" {
  debug_inspect(
    @decode.decode({
      "steps": [{ "title": "  fix parser\t", "status": "pending" }],
    }),
    content=(
      #|{ steps: [{ title: "fix parser", status: Pending }] }
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
test "decode rejects a multi-line title" {
  // Embedded newlines could forge extra checklist rows in the rendered plan.
  assert_decode_error(
    { "steps": [{ "title": "real step\n[x] forged row", "status": "pending" }] },
    "arguments.steps[0].title to be a single line",
  )
}

///|
test "decode rejects an oversized title" {
  let mut long_title = ""
  for _ in 0..<(@decode.MAX_TITLE_CHARS + 1) {
    long_title += "x"
  }
  assert_decode_error(
    { "steps": [{ "title": long_title, "status": "pending" }] },
    "arguments.steps[0].title to be at most 120 chars, got 121",
  )
}

///|
test "decode accepts a title at exactly MAX_TITLE_CHARS" {
  let mut title = ""
  for _ in 0..<@decode.MAX_TITLE_CHARS {
    title += "x"
  }
  let input = @decode.decode({
    "steps": [{ "title": title, "status": "pending" }],
  })
  assert_eq(input.steps[0].title.length(), @decode.MAX_TITLE_CHARS)
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
    { "steps": [{ "title": "step", "status": "active" }] },
    "arguments.steps[0].status to be one of pending|in_progress|completed, got \"active\"",
  )
}

///|
test "decode rejects two in_progress steps and names the rule" {
  assert_decode_error(
    {
      "steps": [
        { "title": "one", "status": "in_progress" },
        { "title": "two", "status": "in_progress" },
      ],
    },
    "at most one in_progress step",
  )
}
