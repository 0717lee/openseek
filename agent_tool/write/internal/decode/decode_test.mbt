///|
test "decode valid write input" {
  debug_inspect(
    @decode.decode({ "path": "/tmp/file.txt", "content": "hello" }),
    content=(
      #|{
      #|  path: "/tmp/file.txt",
      #|  content: "hello",
      #|  revert_on_parse_errors: true,
      #|}

    ),
  )
}

///|
test "decode accepts empty content" {
  debug_inspect(
    @decode.decode({ "path": "/tmp/file.txt", "content": "" }),
    content=(
      #|{ path: "/tmp/file.txt", content: "", revert_on_parse_errors: true }
    ),
  )
}

///|
test "decode reads revert_on_parse_errors" {
  debug_inspect(
    @decode.decode({
      "path": "/tmp/fixture.mbt",
      "content": "broken(",
      "revert_on_parse_errors": false,
    }),
    content=(
      #|{
      #|  path: "/tmp/fixture.mbt",
      #|  content: "broken(",
      #|  revert_on_parse_errors: false,
      #|}

    ),
  )
  // Null is treated as absent, keeping the guard on.
  debug_inspect(
    @decode.decode({
      "path": "/tmp/a.mbt",
      "content": "x",
      "revert_on_parse_errors": Json::null(),
    }),
    content=(
      #|{ path: "/tmp/a.mbt", content: "x", revert_on_parse_errors: true }
    ),
  )
}

///|
test "decode rejects non-boolean revert_on_parse_errors" {
  try
    @decode.decode({
      "path": "/tmp/a.mbt",
      "content": "x",
      "revert_on_parse_errors": 1,
    })
  catch {
    error =>
      assert_true(
        "\{error}".contains("arguments.revert_on_parse_errors to be a boolean"),
      )
  } noraise {
    _ => fail("non-boolean flag decoded")
  }
}

///|
test "decode rejects missing content" {
  try @decode.decode({ "path": "/tmp/file.txt" }) catch {
    error => assert_true("\{error}".contains("arguments.content"))
  } noraise {
    _ => fail("missing content decoded")
  }
}

///|
test "decode rejects missing path" {
  try @decode.decode({ "content": "hello" }) catch {
    error => assert_true("\{error}".contains("arguments.path"))
  } noraise {
    _ => fail("missing path decoded")
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
