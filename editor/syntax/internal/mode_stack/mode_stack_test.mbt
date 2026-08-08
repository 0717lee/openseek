///|
test "mode stack reads the encoded state without an Array" {
  let base = @mode_stack.normalize(TokenizerState(""))
  assert_eq(@mode_stack.top(base), 'n')
  assert_eq(base, TokenizerState("n"))
  let template = @mode_stack.push(base, 't')
  let interpolation = @mode_stack.push(template, 'i')
  let nested = @mode_stack.push(interpolation, 'b')
  assert_eq(@mode_stack.top(nested), 'b')
  assert_eq(nested, TokenizerState("ntib"))
  assert_eq(@mode_stack.pop(nested), interpolation)
  assert_eq(@mode_stack.pop(interpolation), template)
  assert_eq(@mode_stack.pop(template), base)
  assert_eq(@mode_stack.pop(base), base)
  let supplementary : @syntax.TokenizerState = TokenizerState("\u{1F600}")
  assert_eq(@mode_stack.top(supplementary), '\u{1F600}')
  assert_eq(@mode_stack.pop(supplementary), supplementary)
}
