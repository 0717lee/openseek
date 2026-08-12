# syntax/lang_moon_config

The textual `moon.mod` and `moon.pkg` lexer. It implements
`@syntax.LineTokenizer` with a compile-time `lexmatch` DFA and follows the
official `source.moonbit.config` lexical classes.

`MoonConfigTokenizer` is the whole public surface. Hosts register it for the
`moonbit-config` language id; reusable viewer core packages must not import it.

## Token roles

The lexer assigns tokens from their text alone: one rule consumes each complete
identifier, then a spelling-only classifier recognizes imports, configuration
calls, aliases, and constants. All other names remain identifiers regardless of
their grammatical position. Syntactic or semantic property highlighting can be
layered on later without mixing parsing into this lexical pass.

```mbt check
///|
test "tokenizes a package manifest" {
  let tokenizer : &@syntax.LineTokenizer = @lang_moon_config.MoonConfigTokenizer()
  let (tokens, next_state) = tokenizer.tokenize_line(
    "supported_targets = \"js\" // browser only",
    tokenizer.initial_state(),
  )
  debug_inspect(
    (tokens, next_state),
    content=(
      #|(
      #|  [
      #|    { start: 0, end: 17, tag: Identifier },
      #|    { start: 18, end: 19, tag: Operator },
      #|    { start: 20, end: 24, tag: String },
      #|    { start: 25, end: 40, tag: Comment },
      #|  ],
      #|  TokenizerState(""),
      #|)
    ),
  )
}
```

MoonBit configuration strings and comments cannot cross a line boundary, so
the tokenizer always returns the canonical empty state. Unterminated strings
remain colored through the end of their line and the following line recovers
in normal mode.

## Boundaries and checks

This package depends only on `syntax`. The complete public API is recorded in
`pkg.generated.mbti`.

```sh
moon test --target js syntax/lang_moon_config
```
