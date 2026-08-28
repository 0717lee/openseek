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
test "specialized providers group touching rows into VS Code hunks" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(mode~)
    let result = compute_with_provider(
      provider, "fn value() {\n  let first = 1\n  let second = 2\n}", "fn value() {\n  let first = 10\n  let second = 20\n}",
    )
    assert_eq(result.changes.length(), 1)
    assert_eq(result.changes[0].original, LineRange(2, 4))
    assert_eq(result.changes[0].modified, LineRange(2, 4))
    provider.dispose()
  }
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
test "invalid Tree geometry falls back to strict Core" {
  let original = "fn stable() { 0 }"
  let modified = "fn inserted() { 1 }\nfn stable() { 2 }"
  let options : @diff.DocumentDiffOptions = { ignore_trim_whitespace: false, }
  let expected = @diff.CoreDocumentDiffProvider().compute_diff(
    TextSnapshot(original),
    TextSnapshot(modified),
    options,
  )
  for ignore_comments in [false, true] {
    let provider = MoonDocumentDiffProvider(mode=Tree, ignore_comments~)
    let result = compute_with_provider(
      provider,
      original,
      modified,
      ignore_trim_whitespace=false,
    )
    assert_eq(result, expected)
    assert_eq(provider.get_status(), {
      requested: Tree,
      effective: Core,
      fell_back: true,
    })
    provider.dispose()
  }
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
test "Token keeps ignored inserted comments separate from code insertions" {
  let provider = MoonDocumentDiffProvider(mode=Token, ignore_comments=true)
  let result = compute_with_provider(
    provider, "fn stable() {}", "/// ignored before\nfn inserted() {}\n/// ignored after\nfn stable() {}",
  )
  guard result.changes is [change] else {
    fail("expected one inserted code change")
  }
  assert_eq(change.original, LineRange(1, 1))
  assert_eq(change.modified, LineRange(2, 3))
  assert_eq(result.additional_alignments, [
    LineRangeMapping(LineRange(1, 1), LineRange(1, 2)),
    LineRangeMapping(LineRange(1, 1), LineRange(3, 4)),
  ])
  assert_eq(provider.get_status(), {
    requested: Token,
    effective: Token,
    fell_back: false,
  })
  provider.dispose()
}

///|
test "Token keeps ignored deleted comments separate from code deletions" {
  let provider = MoonDocumentDiffProvider(mode=Token, ignore_comments=true)
  let result = compute_with_provider(
    provider, "/// ignored before\nfn deleted() {}\n/// ignored after\nfn stable() {}",
    "fn stable() {}",
  )
  guard result.changes is [change] else {
    fail("expected one deleted code change")
  }
  assert_eq(change.original, LineRange(2, 3))
  assert_eq(change.modified, LineRange(1, 1))
  assert_eq(result.additional_alignments, [
    LineRangeMapping(LineRange(1, 2), LineRange(1, 1)),
    LineRangeMapping(LineRange(3, 4), LineRange(1, 1)),
  ])
  assert_eq(provider.get_status(), {
    requested: Token,
    effective: Token,
    fell_back: false,
  })
  provider.dispose()
}

///|
test "Token does not join inserted code across an ignored comment" {
  let provider = MoonDocumentDiffProvider(mode=Token, ignore_comments=true)
  let result = compute_with_provider(
    provider, "fn stable() {}", "fn inserted_before() {}\n/// ignored\nfn inserted_after() {}\nfn stable() {}",
  )
  assert_eq(result.changes.map(change => (change.original, change.modified)), [
    (LineRange(1, 1), LineRange(1, 2)),
    (LineRange(1, 1), LineRange(3, 4)),
  ])
  assert_eq(result.additional_alignments, [
    LineRangeMapping(LineRange(1, 1), LineRange(2, 3)),
  ])
  assert_eq(provider.get_status().effective, Token)
  provider.dispose()
}

///|
test "Token does not join deleted code across an ignored comment" {
  let provider = MoonDocumentDiffProvider(mode=Token, ignore_comments=true)
  let result = compute_with_provider(
    provider, "fn deleted_before() {}\n/// ignored\nfn deleted_after() {}\nfn stable() {}",
    "fn stable() {}",
  )
  assert_eq(result.changes.map(change => (change.original, change.modified)), [
    (LineRange(1, 2), LineRange(1, 1)),
    (LineRange(3, 4), LineRange(1, 1)),
  ])
  assert_eq(result.additional_alignments, [
    LineRangeMapping(LineRange(2, 3), LineRange(1, 1)),
  ])
  assert_eq(provider.get_status().effective, Token)
  provider.dispose()
}

///|
test "invalid specialized candidates settle to Core without reentrant changes" {
  let original = @model.TextSnapshot("fn stable() {}")
  let modified = @model.TextSnapshot(
    "/// ignored before\nfn inserted() {}\n/// ignored after\nfn stable() {}",
  )
  let invalid : @diff.DocumentDiff = {
    changes: [DetailedLineRangeMapping(LineRange(1, 1), LineRange(2, 3), None)],
    additional_alignments: [LineRangeMapping(LineRange(1, 1), LineRange(1, 4))],
  }
  let options : @diff.DocumentDiffOptions = { ignore_trim_whitespace: true, }
  let expected = @diff.CoreDocumentDiffProvider().compute_diff(
    original, modified, options,
  )
  for configuration in [(Token, Token, false), (Tree, Token, true)] {
    let (requested, specialized_effective, specialized_fell_back) = configuration
    let provider = MoonDocumentDiffProvider(mode=requested)
    let provider_object : &@diff.DocumentDiffProvider = provider
    let updates = Ref(0)
    let subscription = provider_object.on_did_change(() => updates.val += 1)
    let result = provider.settle_specialized_or_core(
      requested,
      Some((invalid, specialized_effective, specialized_fell_back)),
      expected,
      original,
      modified,
    )
    assert_eq(result, expected)
    assert_eq(provider.get_status(), {
      requested,
      effective: Core,
      fell_back: true,
    })
    assert_eq(updates.val, 0)
    provider.set_ignore_comments(false)
    assert_eq(provider.get_status(), {
      requested,
      effective: requested,
      fell_back: false,
    })
    assert_eq(updates.val, 1)
    subscription.dispose()
    provider.dispose()
  }
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
