///|
test "percent_decode passes plain segments through" {
  inspect(
    percent_decode("tui-20260610-124146-251"),
    content="tui-20260610-124146-251",
  )
}

///|
test "percent_decode resolves ASCII escapes" {
  inspect(percent_decode("with%20space"), content="with space")
  inspect(percent_decode("100%25"), content="100%")
  inspect(percent_decode("a%3Fb%23c"), content="a?b#c")
}

///|
test "percent_decode handles lowercase hex and UTF-8 byte sequences" {
  inspect(percent_decode("a%2fb"), content="a/b")
  inspect(percent_decode("%E4%B8%AD"), content="中")
}

///|
test "percent_decode leaves malformed escapes verbatim" {
  inspect(percent_decode("%zz"), content="%zz")
  inspect(percent_decode("tail%2"), content="tail%2")
  inspect(percent_decode("bare%"), content="bare%")
}

///|
test "valid_session_id mirrors the store's id rules" {
  inspect(valid_session_id("tui-20260610-124146-251"), content="true")
  inspect(valid_session_id("with space"), content="true")
  inspect(valid_session_id(""), content="false")
  inspect(valid_session_id("."), content="false")
  inspect(valid_session_id(".."), content="false")
  inspect(valid_session_id("a/b"), content="false")
  inspect(valid_session_id("a\\b"), content="false")
}
