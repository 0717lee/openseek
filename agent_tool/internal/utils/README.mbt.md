# agent_tool/internal/utils

One function, `code_unit_prefix`, that truncates text to a UTF-16 code-unit
budget without ever splitting a surrogate pair.

Tool output is capped so a single `read` cannot flood the model's context. The
cap is counted in UTF-16 code units, but a non-BMP character — an emoji, a rare
CJK ideograph, a musical symbol — occupies *two* of them. Cutting between the
two halves produces a lone surrogate: not a character, and not valid UTF-8 once
the result is serialized into a tool response. This package is where that rule
lives so it is written once rather than in every tool that renders output.

`agent_tool/read` is the current caller.

## The budget is a ceiling, never a target

The result is at most `max_units` code units and may be shorter — by one, when
the budget lands mid-pair. It is a *soft* cap in the other direction too: text
already within budget is returned whole, never padded.

```mbt check
///|
test "a surrogate pair is kept whole or dropped entirely" {
  // "😀Z" is three code units: the emoji takes two, "Z" takes one.
  inspect(@utils.code_unit_prefix("😀Z", 3), content="😀Z")
  inspect(@utils.code_unit_prefix("😀Z", 2), content="😀")
  // A budget of 1 would land between the emoji's two halves, so it steps back
  // to 0 rather than emit a lone surrogate.
  inspect(@utils.code_unit_prefix("😀Z", 1), content="")
  inspect(@utils.code_unit_prefix("😀Z", 0), content="")
}

///|
test "text within budget comes back whole" {
  inspect(@utils.code_unit_prefix("abc", 3), content="abc")
  inspect(@utils.code_unit_prefix("abc", 10), content="abc")
  // Non-positive budgets are empty, not an error.
  inspect(@utils.code_unit_prefix("abc", 0), content="")
  inspect(@utils.code_unit_prefix("abc", -5), content="")
}
```

Only a boundary that would split a pair costs a unit. A budget landing on an
ordinary character, or just after a complete pair, is used in full:

```mbt check
///|
test "only a split boundary costs a code unit" {
  // Cutting after the pair — no step back needed.
  inspect(@utils.code_unit_prefix("ab😀cd", 4), content="ab😀")
  // Cutting inside it — one unit given up.
  inspect(@utils.code_unit_prefix("ab😀cd", 3), content="ab")
  // Cutting in plain text — exact.
  inspect(@utils.code_unit_prefix("ab😀cd", 2), content="ab")
  inspect(@utils.code_unit_prefix("abcdef", 4), content="abcd")
}
```

## Notes for callers

The parameter and result are `StringView`, so a truncation that keeps everything
— the common case — allocates nothing and the slice shares the original buffer.
Pass a `String` directly; the conversion is implicit.

This counts **code units, not characters and not grapheme clusters**. A combining
mark or an emoji ZWJ sequence can still be cut in the middle: the result stays
valid UTF-16, but a family emoji may render as its separate members. That is
deliberate — the budget exists to bound bytes, and clustering rules would make
the bound depend on Unicode tables.

```mbt check
///|
test "clusters may split; only pairs are protected" {
  // "e" followed by a combining acute accent — two code units, one grapheme.
  // Cutting at 1 keeps the base letter and drops the accent: still valid text,
  // just a different glyph.
  inspect(@utils.code_unit_prefix("e\u{0301}", 1), content="e")
}
```
