///|
test "clamps ints" {
  assert_eq((-1).clamp(min=0, max=10), 0)
  assert_eq((4).clamp(min=0, max=10), 4)
  assert_eq((99).clamp(min=0, max=10), 10)
}
