///|
test "code_unit_prefix keeps whole surrogate pairs" {
  assert_eq(@utils.code_unit_prefix("😀Z", 0), "")
  assert_eq(@utils.code_unit_prefix("😀Z", 1), "")
  assert_eq(@utils.code_unit_prefix("😀Z", 2), "😀")
  assert_eq(@utils.code_unit_prefix("😀Z", 3), "😀Z")
}

///|
test "code_unit_prefix returns full content when within budget" {
  assert_eq(@utils.code_unit_prefix("abc", 3), "abc")
  assert_eq(@utils.code_unit_prefix("abc", 10), "abc")
}
