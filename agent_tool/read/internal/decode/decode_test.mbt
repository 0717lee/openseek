///|
test "decode valid read input" {
  debug_inspect(
    @decode.decode({
      "path": "file.mbt",
      "start_line": 3,
      "max_lines": 4,
      "max_output_chars": 999999,
    }),
    content=(
      #|{
      #|  path: "file.mbt",
      #|  start_line: 3,
      #|  max_lines: Some(4),
      #|  max_output_chars: 50000,
      #|}
    ),
  )
}

///|
test "decode defaults optional limits" {
  debug_inspect(
    @decode.decode({ "path": "file.mbt" }),
    content=(
      #|{
      #|  path: "file.mbt",
      #|  start_line: 1,
      #|  max_lines: None,
      #|  max_output_chars: 12000,
      #|}
    ),
  )
}

///|
test "decode rejects missing path" {
  try @decode.decode({}) catch {
    error => assert_true("\{error}".contains("arguments.path"))
  } noraise {
    _ => fail("missing path decoded")
  }
}

///|
test "decode rejects paths array" {
  try @decode.decode({ "paths": ["a.mbt", "b.mbt"] }) catch {
    error =>
      assert_true("\{error}".contains("arguments.paths is not supported"))
  } noraise {
    _ => fail("paths decoded")
  }
}

///|
test "decode rejects invalid limits" {
  try @decode.decode({ "path": "file.mbt", "max_lines": 0 }) catch {
    error =>
      assert_true(
        "\{error}".contains("arguments.max_lines to be a positive number"),
      )
  } noraise {
    _ => fail("invalid max_lines decoded")
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
