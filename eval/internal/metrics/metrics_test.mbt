///|
test "count_occurrences counts non-overlapping markers" {
  assert_eq(
    @metrics.count_occurrences("tool error: a\ntool error: b", "tool error:"),
    2,
  )
  assert_eq(@metrics.count_occurrences("abc", "z"), 0)
  assert_eq(@metrics.count_occurrences("abc", ""), 0)
}

///|
test "count_lines_containing_all documents all-match behavior" {
  let log_text =
    #|command=moon run -e fn main {}
    #|command=moon run -c fn main {}
    #|command=moon test
    #|note=moon run without command prefix
  debug_inspect(
    [
      @metrics.count_lines_containing_all(log_text, ["command=moon "]),
      @metrics.count_lines_containing_all(log_text, ["moon run", " -e"]),
      @metrics.count_lines_containing_all(log_text, ["moon run", " -c"]),
      @metrics.count_lines_containing_all(log_text, ["command=moon ", "missing"]),
      @metrics.count_lines_containing_all("a\nb\n", []),
    ],
    content="[3, 1, 1, 0, 3]",
  )
}
