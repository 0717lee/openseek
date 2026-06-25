///|
test "decode valid edit input" {
  debug_inspect(
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "start_line": 1,
    }),
    content=(
      #|{
      #|  path: "file.mbt",
      #|  old_string: "old",
      #|  new_string: "new",
      #|  replace_all: false,
      #|  start_line: 1,
      #|  end_line: None,
      #|}
    ),
  )
}

///|
test "decode replace_all flag" {
  debug_inspect(
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "replace_all": true,
      "start_line": 1,
    }),
    content=(
      #|{
      #|  path: "file.mbt",
      #|  old_string: "old",
      #|  new_string: "new",
      #|  replace_all: true,
      #|  start_line: 1,
      #|  end_line: None,
      #|}
    ),
  )
}

///|
test "decode line range" {
  debug_inspect(
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "start_line": 2,
      "end_line": 4,
    }),
    content=(
      #|{
      #|  path: "file.mbt",
      #|  old_string: "old",
      #|  new_string: "new",
      #|  replace_all: false,
      #|  start_line: 2,
      #|  end_line: Some(4),
      #|}
    ),
  )
}

///|
test "decode rejects invalid replace_all" {
  try
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "replace_all": "yes",
      "start_line": 1,
    })
  catch {
    error => assert_true("\{error}".contains("arguments.replace_all"))
  } noraise {
    _ => fail("invalid replace_all decoded")
  }
}

///|
test "decode rejects invalid line range" {
  try
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "start_line": 0,
    })
  catch {
    error =>
      assert_true(
        "\{error}".contains("arguments.start_line to be a positive integer"),
      )
  } noraise {
    _ => fail("invalid start_line decoded")
  }
  try
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "start_line": 1,
      "end_line": "4",
    })
  catch {
    error =>
      assert_true("\{error}".contains("arguments.end_line to be an integer"))
  } noraise {
    _ => fail("invalid end_line decoded")
  }
  try
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "start_line": 1.9,
    })
  catch {
    error =>
      assert_true("\{error}".contains("arguments.start_line to be an integer"))
  } noraise {
    _ => fail("fractional start_line decoded")
  }
  try
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
      "start_line": 4,
      "end_line": 2,
    })
  catch {
    error =>
      assert_true(
        "\{error}".contains(
          "arguments.end_line to be greater than or equal to arguments.start_line",
        ),
      )
  } noraise {
    _ => fail("inverted line range decoded")
  }
}

///|
test "decode rejects missing required fields" {
  try @decode.decode({ "path": "file.mbt" }) catch {
    error => assert_true("\{error}".contains("arguments.old_string"))
  } noraise {
    _ => fail("missing old_string decoded")
  }
  try @decode.decode({ "path": "file.mbt", "old_string": "old" }) catch {
    error => assert_true("\{error}".contains("arguments.new_string"))
  } noraise {
    _ => fail("missing new_string decoded")
  }
  try
    @decode.decode({
      "path": "file.mbt",
      "old_string": "old",
      "new_string": "new",
    })
  catch {
    error => assert_true("\{error}".contains("arguments.start_line"))
  } noraise {
    _ => fail("missing start_line decoded")
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
