///|
test "decode direct moon_check arguments" {
  debug_inspect(
    decode({
      "cwd": "/tmp",
      "target": "native",
      "warn_list": "+unnecessary_annotation",
      "deny_warn": true,
      "fmt": true,
      "explain": true,
    }),
    content=(
      #|{
      #|  cwd: Some("/tmp"),
      #|  target: Some("native"),
      #|  warn_list: Some("+unnecessary_annotation"),
      #|  deny_warn: true,
      #|  fmt: true,
      #|  explain: true,
      #|}
    ),
  )
}

///|
test "decode ignores empty optional strings and false flags" {
  debug_inspect(
    decode({ "cwd": "", "deny_warn": false, "fmt": null }),
    content=(
      #|{
      #|  cwd: None,
      #|  target: None,
      #|  warn_list: None,
      #|  deny_warn: false,
      #|  fmt: false,
      #|  explain: false,
      #|}
    ),
  )
}

///|
test "decode rejects invalid target" {
  try decode({ "target": "browser" }) catch {
    error => assert_true("\{error}".contains("arguments.target"))
  } noraise {
    _ => fail("invalid target decoded")
  }
}

///|
test "decode rejects non-object arguments" {
  try decode(Json::null()) catch {
    error => assert_true("\{error}".contains("object arguments"))
  } noraise {
    _ => fail("non-object decoded")
  }
}
