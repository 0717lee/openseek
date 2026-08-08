///|
test "mode stack reads the encoded state without an Array" {
  let base = @mode_stack.normalize(TokenizerState(""))
  assert_eq(@mode_stack.top(base), 'n')
  assert_eq(base, TokenizerState("n"))
  let nested = @mode_stack.normalize(TokenizerState("ntib"))
  assert_eq(@mode_stack.top(nested), 'b')
  assert_eq(nested, TokenizerState("ntib"))
}
