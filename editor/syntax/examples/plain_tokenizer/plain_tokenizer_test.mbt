///|
test "plain tokenizer counts UTF-16 code units and keeps pairs whole" {
  // 𐍈 (U+10348) is two UTF-16 code units; the identifier after it must
  // start at offset 4 and the pair must stay one token.
  let plain : &@syntax.LineTokenizer = @plain_tokenizer.PlainTokenizer()
  let (tokens, _) = plain.tokenize_line("a \u{10348}b", plain.initial_state())
  debug_inspect(
    tokens,
    content=(
      #|[
      #|  { start: 0, end: 1, tag: Identifier },
      #|  { start: 2, end: 4, tag: Punctuation },
      #|  { start: 4, end: 5, tag: Identifier },
      #|]
    ),
  )
}
