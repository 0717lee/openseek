///|
test "one_line collapses newlines and trims whitespace" {
  assert_eq(one_line("  alpha\nbeta  "), "alpha beta")
}

///|
test "truncate caps by character without splitting surrogate pairs" {
  assert_eq(truncate("hello world", 5), "hello…")
  assert_eq(truncate("a🤣b", 2), "a🤣…")
}
