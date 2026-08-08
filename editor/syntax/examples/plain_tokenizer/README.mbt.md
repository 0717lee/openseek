# Plain tokenizer example

This package is a deliberately small reference implementation of
`@syntax.LineTokenizer`. It is kept outside the main `syntax` package so the
core interface contains only the tokenization contract and registry.

`PlainTokenizer` is useful in examples and tests that need a concrete tokenizer
without choosing a real language. It is not the editor's automatic fallback:
when no tokenizer is registered, the model emits one `Plain` token for the
whole line without invoking this package.

Despite its name, the example performs lightweight MoonBit-ish highlighting.
It recognizes a fixed keyword list, identifiers, decimal numbers,
double-quoted strings with backslash escapes, `//` comments, and punctuation.
It is stateless and preserves the state passed to `tokenize_line`.

```mbt check
///|
test "the example applies generic classes and never changes state" {
  let tokenizer : &@syntax.LineTokenizer = @plain_tokenizer.PlainTokenizer()
  let initial = tokenizer.initial_state()
  let (tokens, next) = tokenizer.tokenize_line("let x = 1", initial)
  debug_inspect(
    (tokens, next == initial),
    content=(
      #|(
      #|  [
      #|    { start: 0, end: 3, tag: Keyword },
      #|    { start: 4, end: 5, tag: Identifier },
      #|    { start: 6, end: 7, tag: Punctuation },
      #|    { start: 8, end: 9, tag: Number },
      #|  ],
      #|  true,
      #|)
    ),
  )
}
```

Register it explicitly when a test or example needs it:

```mbt check
///|
test "explicit registration" {
  let registry = @syntax.TokenizationRegistry()
  let registration = registry.register(
    "example",
    @plain_tokenizer.PlainTokenizer(),
  )
  assert_true(registry.get("example") is Some(_))
  registration.dispose()
}
```
