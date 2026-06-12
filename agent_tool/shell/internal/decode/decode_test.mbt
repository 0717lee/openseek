///|
test "decode valid shell input" {
  debug_inspect(
    @decode.decode({
      "cmd": "echo hello",
      "cwd": "/tmp",
      "timeout_ms": 250,
      "max_output_chars": 999999,
    }),
    content=(
      #|{
      #|  cmd: "echo hello",
      #|  cwd: Some("/tmp"),
      #|  timeout_ms: Some(250),
      #|  max_output_chars: 50000,
      #|}
    ),
  )
}

///|
test "decode treats empty cwd as absent" {
  debug_inspect(
    @decode.decode({ "cmd": "pwd", "cwd": "" }),
    content=(
      #|{ cmd: "pwd", cwd: None, timeout_ms: None, max_output_chars: 12000 }
    ),
  )
}

///|
test "decode rejects missing command" {
  try @decode.decode({ "cwd": "/tmp" }) catch {
    error => assert_true("\{error}".contains("arguments.cmd"))
  } noraise {
    _ => fail("missing command decoded")
  }
}

///|
test "decode rejects invalid output cap" {
  try @decode.decode({ "cmd": "echo hello", "max_output_chars": 0 }) catch {
    error =>
      assert_true(
        "\{error}".contains(
          "arguments.max_output_chars to be a positive number",
        ),
      )
  } noraise {
    _ => fail("invalid output cap decoded")
  }
}

///|
test "decode rejects invalid timeout" {
  try @decode.decode({ "cmd": "echo hello", "timeout_ms": 0 }) catch {
    error =>
      assert_true(
        "\{error}".contains("arguments.timeout_ms to be a positive number"),
      )
  } noraise {
    _ => fail("invalid timeout decoded")
  }
}

///|
test "decode rejects non-object arguments" {
  try @decode.decode(Json::null()) catch {
    error => assert_true("\{error}".contains("object arguments"))
  } noraise {
    _ => fail("non-object decoded")
  }
}
