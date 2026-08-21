///|
fn compute_with_provider(
  provider : MoonDocumentDiffProvider,
  original : String,
  modified : String,
  ignore_trim_whitespace? : Bool = true,
) -> @diff.DocumentDiff raise {
  let object : &@diff.DocumentDiffProvider = provider
  object.compute_diff(TextSnapshot(original), TextSnapshot(modified), {
    ignore_trim_whitespace,
  })
}

///|
test "Token and Tree honor trim-whitespace options consistently" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(mode~)
    let ignored = compute_with_provider(
      provider,
      "  fn answer() { 1 }\t",
      "fn answer() { 1 }",
      ignore_trim_whitespace=true,
    )
    assert_true(ignored.changes.is_empty())
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: Core,
      fell_back: true,
    })
    let preserved = compute_with_provider(
      provider,
      "  fn answer() { 1 }\t",
      "fn answer() { 1 }",
      ignore_trim_whitespace=false,
    )
    assert_false(preserved.changes.is_empty())
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: Core,
      fell_back: true,
    })
    provider.dispose()
  }
}

///|
test "trim-insensitive input keeps the specialized provider" {
  let provider = MoonDocumentDiffProvider(mode=Token)
  let result = compute_with_provider(
    provider,
    "fn answer() { 1 }",
    "fn answer() { 2 }",
    ignore_trim_whitespace=true,
  )
  assert_eq(result.changes.length(), 1)
  assert_eq(provider.get_status(), {
    requested: Token,
    effective: Token,
    fell_back: false,
  })
  provider.dispose()
}

///|
test "Token provider exposes UTF-16 inner mappings" {
  let provider = MoonDocumentDiffProvider(mode=Token)
  let result = compute_with_provider(
    provider, "fn answer() { \"😀\"; 1 }", "fn answer() { \"😀\"; 2 }",
  )
  guard result.changes is [change] else { fail("expected one token change") }
  guard change.inner_changes is Some([inner]) else {
    fail("expected one paired inner mapping")
  }
  assert_eq(inner.original, Range(1, 21, 1, 22))
  assert_eq(inner.modified, Range(1, 21, 1, 22))
  assert_eq(provider.get_status(), {
    requested: Token,
    effective: Token,
    fell_back: false,
  })
  provider.dispose()
}

///|
test "Tree parse failure reports Token fallback" {
  let provider = MoonDocumentDiffProvider(mode=Tree)
  let result = compute_with_provider(provider, "fn broken( {", "fn okay() {}")
  assert_false(result.changes.is_empty())
  assert_eq(provider.get_status(), {
    requested: Tree,
    effective: Token,
    fell_back: true,
  })
  provider.dispose()
}

///|
test "ignored-only rows become geometry-only additional alignments" {
  let provider = MoonDocumentDiffProvider(mode=Token, ignore_comments=true)
  let result = compute_with_provider(
    provider, "fn value() -> Int {\n  // obsolete note\n  1\n}", "fn value() -> Int {\n\n  // updated note\n  1\n}",
  )
  assert_true(result.changes.is_empty())
  assert_eq(result.additional_alignments.length(), 1)
  provider.dispose()
}

///|
test "equal-length ignored-only edit is a valid empty specialized result" {
  let provider = MoonDocumentDiffProvider(mode=Token, ignore_comments=true)
  let result = compute_with_provider(
    provider, "fn value() {\n  // old\n}", "fn value() {\n  // new\n}",
  )
  assert_true(result.changes.is_empty())
  assert_true(result.additional_alignments.is_empty())
  assert_eq(provider.get_status().effective, Token)
  assert_false(provider.get_status().fell_back)
  provider.dispose()
}

///|
test "provider options notify through the standard provider contract" {
  let provider = MoonDocumentDiffProvider()
  let object : &@diff.DocumentDiffProvider = provider
  let updates = Ref(0)
  let subscription = object.on_did_change(() => updates.val += 1)
  provider.set_mode(Token)
  provider.set_ignore_comments(false)
  provider.set_ignore_comments(false)
  assert_eq(updates.val, 2)
  subscription.dispose()
  provider.dispose()
}
