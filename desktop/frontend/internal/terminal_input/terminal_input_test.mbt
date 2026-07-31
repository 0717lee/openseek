///|
test "encode_binary preserves each xterm code unit as one byte" {
  assert_eq(
    @terminal_input.encode_binary("\u{0000}\u{007f}\u{0080}\u{00ff}"),
    "AH+A/w==",
  )
}
