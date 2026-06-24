///|
test "cap_text truncates to max_chars and leaves shorter text alone" {
  assert_eq(@output.cap_text("abcdef", 3), "abc")
  assert_eq(@output.cap_text("abc", 3), "abc")
  assert_eq(@output.cap_text("ab", 3), "ab")
}

///|
test "truncation reporting" {
  assert_true(@output.is_truncated("abcdef", 3))
  assert_false(@output.is_truncated("abc", 3))
  assert_eq(
    @output.truncation_header("abcdef", 3),
    "\ntruncated=true\noutput_chars=6\nshown_chars=3",
  )
  assert_eq(@output.truncation_header("abc", 3), "")
}
