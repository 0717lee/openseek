///|
test "cap_text truncates to max_chars and leaves shorter text alone" {
  assert_eq(@output.cap_text("abcdef", 3), "abc")
  assert_eq(@output.cap_text("abc", 3), "abc")
  assert_eq(@output.cap_text("ab", 3), "ab")
}

///|
test "cap_text never splits a surrogate pair" {
  // "😀" is one code point but two UTF-16 code units, so a budget of 1 lands
  // inside it; cap_text drops the whole pair rather than slicing it (which would
  // abort). "x😀" with a budget of 2 likewise keeps only the leading "x".
  assert_eq(@output.cap_text("😀x", 1), "")
  assert_eq(@output.cap_text("😀x", 2), "😀")
  assert_eq(@output.cap_text("x😀y", 2), "x")
}

///|
test "truncation_header shown_chars matches what cap_text keeps" {
  // At a surrogate boundary cap_text keeps fewer than the budget, and the header
  // reports that smaller, accurate count rather than the requested max.
  assert_eq(@output.cap_text("😀x", 1), "")
  assert_eq(
    @output.truncation_header("😀x", 1),
    "\ntruncated=true\noutput_chars=3\nshown_chars=0",
  )
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
