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
    let mixed = compute_with_provider(
      provider,
      "fn answer() {\n  old_value()\n}",
      "fn answer() {\n  new_value()\n }",
      ignore_trim_whitespace=true,
    )
    assert_false(mixed.changes.is_empty())
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
test "Token provider preserves one-sided token mappings across multiline expansion" {
  let original = "fn run() {\n  compute(alpha, beta)\n}"
  let modified = "fn run() {\n  compute(\n    alpha,\n    beta,\n    gamma < limit,\n  )\n}"
  let inserted_comma = @base_common.Range(4, 9, 4, 10)
  let inserted_argument = @base_common.Range(5, 5, 5, 19)
  let forward = MoonDocumentDiffProvider(mode=Token)
  let forward_result = compute_with_provider(forward, original, modified)
  guard forward_result.changes is [forward_change] else {
    fail("expected one grouped expansion hunk")
  }
  assert_eq(forward_change.original, LineRange(2, 3))
  assert_eq(forward_change.modified, LineRange(2, 7))
  guard forward_change.inner_changes is Some(forward_inner) else {
    fail("expected token mappings for expanded lines")
  }
  assert_eq(forward_inner.map(mapping => mapping.modified), [
    inserted_comma, inserted_argument,
  ])
  assert_eq(forward_inner.map(mapping => mapping.original), [
    @base_common.Range(3, 1, 3, 1),
    @base_common.Range(3, 1, 3, 1),
  ])
  assert_true(forward_result.additional_alignments.is_empty())
  assert_eq(forward.get_status(), {
    requested: Token,
    effective: Token,
    fell_back: false,
  })
  forward.dispose()

  let reverse = MoonDocumentDiffProvider(mode=Token)
  let reverse_result = compute_with_provider(reverse, modified, original)
  guard reverse_result.changes is [reverse_change] else {
    fail("expected one grouped contraction hunk")
  }
  assert_eq(reverse_change.original, LineRange(2, 7))
  assert_eq(reverse_change.modified, LineRange(2, 3))
  guard reverse_change.inner_changes is Some(reverse_inner) else {
    fail("expected token mappings for contracted lines")
  }
  assert_eq(reverse_inner.map(mapping => mapping.original), [
    inserted_comma, inserted_argument,
  ])
  assert_eq(reverse_inner.map(mapping => mapping.modified), [
    @base_common.Range(3, 1, 3, 1),
    @base_common.Range(3, 1, 3, 1),
  ])
  assert_true(reverse_result.additional_alignments.is_empty())
  assert_eq(reverse.get_status(), {
    requested: Token,
    effective: Token,
    fell_back: false,
  })
  reverse.dispose()
}

///|
test "Token provider marks pure multiline reflow as computed inner changes" {
  let original = "fn run() {\n  compute(alpha, beta)\n}"
  let modified = "fn run() {\n  compute(\n    alpha,\n    beta\n  )\n}"
  let provider = MoonDocumentDiffProvider(mode=Token)
  let result = compute_with_provider(provider, original, modified)
  guard result.changes is [change] else {
    fail("expected one grouped reflow hunk")
  }
  assert_eq(change.original, LineRange(2, 3))
  assert_eq(change.modified, LineRange(2, 6))
  assert_eq(change.inner_changes, Some([]))
  assert_true(result.additional_alignments.is_empty())
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
test "top-level edits keep specialized global mappings" {
  let cases = [
    (
      "fn stable() { 0 }",
      "fn inserted() { 1 }\nfn stable() { 2 }",
      [(@base_common.LineRange(1, 2), @base_common.LineRange(1, 3))],
    ),
    (
      "fn first() {}\nfn last() {}",
      "fn first() {}\nfn inserted() {}\nfn last() {}",
      [(@base_common.LineRange(2, 2), @base_common.LineRange(2, 3))],
    ),
    (
      "fn first() {}",
      "fn first() {}\nfn inserted() {}",
      [(@base_common.LineRange(2, 2), @base_common.LineRange(2, 3))],
    ),
    (
      "fn deleted() { 1 }\nfn stable() { 0 }",
      "fn stable() { 2 }",
      [(@base_common.LineRange(1, 3), @base_common.LineRange(1, 2))],
    ),
    (
      "fn first() {}\nfn deleted() {}\nfn last() {}",
      "fn first() {}\nfn last() {}",
      [(@base_common.LineRange(2, 3), @base_common.LineRange(2, 2))],
    ),
    (
      "fn first() {}\nfn deleted() {}",
      "fn first() {}",
      [(@base_common.LineRange(2, 3), @base_common.LineRange(2, 2))],
    ),
    (
      "fn first() {}\nfn removed() {}\nfn last() {}",
      "fn first() {}\nfn inserted() {}\nfn last() {}",
      [(@base_common.LineRange(2, 3), @base_common.LineRange(2, 3))],
    ),
  ]
  for mode in [Token, Tree] {
    for case in cases {
      let (original, modified, expected) = case
      let provider = MoonDocumentDiffProvider(
        mode~,
        ignore_comments=false,
        ignore_tests=false,
      )
      let result = compute_with_provider(provider, original, modified)
      assert_eq(
        result.changes.map(change => (change.original, change.modified)),
        expected,
      )
      assert_true(result.additional_alignments.is_empty())
      assert_eq(provider.get_status(), {
        requested: mode,
        effective: mode,
        fell_back: false,
      })
      provider.dispose()
    }
  }
}

///|
test "test filtering preserves a mixed top-level gap" {
  let original = "fn first() {}\nfn last() {}"
  let modified = "fn first() {}\ntest \"sample\" { new_test() }\nfn inserted() {}\nfn last() {}"
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let result = compute_with_provider(provider, original, modified)
    assert_eq(
      result.changes.map(change => (change.original, change.modified)),
      [(LineRange(2, 2), LineRange(3, 4))],
    )
    assert_eq(result.additional_alignments, [
      LineRangeMapping(LineRange(2, 2), LineRange(2, 3)),
    ])
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: mode,
      fell_back: false,
    })
    provider.dispose()
  }
}

///|
test "top-level anchors preserve shared gaps and final newlines" {
  let cases = [
    (
      "\nfn last() {}",
      "fn inserted() {}\n\nfn last() {}",
      (@base_common.LineRange(1, 1), @base_common.LineRange(1, 2)),
      None,
    ),
    (
      "fn first() {}\n",
      "fn first() {}\nfn inserted() {}\n",
      (@base_common.LineRange(2, 2), @base_common.LineRange(2, 3)),
      None,
    ),
    (
      "fn first() {}\n",
      "fn first() {}\ntest \"sample\" { new_test() }\nfn inserted() {}\n",
      (@base_common.LineRange(2, 2), @base_common.LineRange(3, 4)),
      Some(
        @diff.LineRangeMapping(
          @base_common.LineRange(2, 2),
          @base_common.LineRange(2, 3),
        ),
      ),
    ),
    (
      "test \"sample\" { old_test() }\nfn stable() {}",
      "test \"sample\" {\n  new_one()\n  new_two()\n}\nfn inserted() {}\nfn stable() {}",
      (@base_common.LineRange(2, 2), @base_common.LineRange(5, 6)),
      Some(
        @diff.LineRangeMapping(
          @base_common.LineRange(1, 2),
          @base_common.LineRange(1, 5),
        ),
      ),
    ),
  ]
  for mode in [Token, Tree] {
    for case in cases {
      let (original, modified, expected_change, expected_alignment) = case
      let provider = MoonDocumentDiffProvider(
        mode~,
        ignore_comments=false,
        ignore_tests=true,
      )
      let result = compute_with_provider(provider, original, modified)
      guard result.changes is [change] else { fail("expected one insertion") }
      assert_eq((change.original, change.modified), expected_change)
      assert_eq(
        result.additional_alignments,
        match expected_alignment {
          Some(alignment) => [alignment]
          None => []
        },
      )
      assert_eq(provider.get_status(), {
        requested: mode,
        effective: mode,
        fell_back: false,
      })
      provider.dispose()
    }
  }
}

///|
test "Ignore tests does not hide ordinary blank-line changes" {
  let original = "fn first() {}\nfn last() {}"
  let modified = "fn first() {}\n\nfn last() {}"
  let expected = @diff.CoreDocumentDiffProvider().compute_diff(
    TextSnapshot(original),
    TextSnapshot(modified),
    { ignore_trim_whitespace: true },
  )
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    assert_eq(compute_with_provider(provider, original, modified), expected)
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: Core,
      fell_back: true,
    })
    provider.dispose()
  }
}

///|
test "ignored-only and matched comment height changes retain geometry" {
  for mode in [Token, Tree] {
    let tests = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let moved = compute_with_provider(
      tests, "test \"sample\" {}\nfn stable() {}", "fn stable() {}\ntest \"sample\" {}",
    )
    assert_true(moved.changes.is_empty())
    assert_eq(moved.additional_alignments, [
      LineRangeMapping(LineRange(1, 2), LineRange(1, 1)),
      LineRangeMapping(LineRange(3, 3), LineRange(2, 3)),
    ])
    assert_eq(tests.get_status().effective, mode)
    tests.dispose()

    let comments = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=true,
      ignore_tests=false,
    )
    let trailing = compute_with_provider(
      comments, "fn stable() {}", "fn stable() {}\n\n",
    )
    assert_true(trailing.changes.is_empty())
    assert_eq(trailing.additional_alignments, [
      LineRangeMapping(LineRange(2, 2), LineRange(2, 4)),
    ])
    assert_eq(comments.get_status().effective, mode)
    let mixed = compute_with_provider(
      comments, "fn first() {\n  // old\n}\nfn last() {}", "fn first() {\n  // new one\n  // new two\n}\nfn inserted() {}\nfn last() {}",
    )
    assert_eq(mixed.changes.map(change => (change.original, change.modified)), [
      (LineRange(4, 4), LineRange(5, 6)),
    ])
    assert_eq(mixed.additional_alignments, [
      LineRangeMapping(LineRange(2, 3), LineRange(2, 4)),
    ])
    assert_eq(comments.get_status().effective, mode)
    comments.dispose()
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
test "Token and Tree ignore MoonBit test-only edits" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let ignored = compute_with_provider(
      provider, "test \"sample\" { old_value() }", "test \"sample\" { new_value() }",
    )
    assert_true(ignored.changes.is_empty())
    assert_true(ignored.additional_alignments.is_empty())
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: mode,
      fell_back: false,
    })
    let reshaped = compute_with_provider(
      provider, "fn first() {}\nfn second() {}\ntest \"old\" {\n  value()\n}", "fn first() {}\nfn second() {}\ntest \"new one\" { value() }\ntest \"new two\" { value() }\ntest \"new three\" { value() }",
    )
    assert_true(reshaped.changes.is_empty())
    assert_true(reshaped.additional_alignments.is_empty())
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: mode,
      fell_back: false,
    })
    let mixed = compute_with_provider(
      provider, "fn a() { old() }\ntest \"old\" {\n  value()\n}", "fn a() { new() }\ntest \"n1\" { value() }\ntest \"n2\" { value() }\ntest \"n3\" { value() }",
    )
    assert_eq(mixed.changes.map(change => (change.original, change.modified)), [
      (LineRange(1, 2), LineRange(1, 2)),
    ])
    assert_true(mixed.additional_alignments.is_empty())
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: mode,
      fell_back: false,
    })
    provider.set_ignore_tests(false)
    let visible = compute_with_provider(
      provider, "test \"sample\" { old_value() }", "test \"sample\" { new_value() }",
    )
    assert_false(visible.changes.is_empty())
    provider.dispose()
  }
}

///|
test "ignored tests do not consume adjacent ordinary blank lines" {
  let original = "fn a() {}\nfn b() {}"
  let modified = "fn a() {}\ntest \"new\" { new_value() }\n\nfn b() {}"
  let metadata = @mbtdiff.diff(
    original,
    modified,
    options=@mbtdiff.DiffOptions(
      context_lines=0,
      ignore_comments=false,
      ignore_tests=true,
      mode=@mbtdiff.DiffMode::Lexical,
    ),
  )
  assert_true(
    metadata.ignored_test_ranges(@mbtdiff.DiffSide::New)
    is [{ start: 1, len: 1 }],
  )
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let result = compute_with_provider(provider, original, modified)
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: Core,
      fell_back: true,
    })
    assert_false(result.changes.is_empty())
    provider.dispose()
  }
}

///|
test "ignored test reshapes preserve multiple semantic gaps" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let result = compute_with_provider(
      provider, "test \"o0\" {\n  value()\n}\ntest \"o1\" {\n  value()\n}\nfn a() {}\nfn b() {}",
      "test \"n0\" { value() }\ntest \"n1\" { value() }\nfn a() {}\ntest \"n2\" {\n  value()\n}\nfn b() {}",
    )
    assert_true(result.changes.is_empty())
    assert_eq(result.additional_alignments, [
      LineRangeMapping(LineRange(1, 7), LineRange(1, 3)),
      LineRangeMapping(LineRange(8, 8), LineRange(4, 7)),
    ])
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: mode,
      fell_back: false,
    })
    provider.dispose()
  }
}

///|
test "ignored inserted tests become geometry-only additional alignments" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let result = compute_with_provider(
      provider, "fn stable() {}", "test \"sample\" { new_value() }\nfn stable() {}",
    )
    assert_true(result.changes.is_empty())
    assert_eq(result.additional_alignments, [
      LineRangeMapping(LineRange(1, 1), LineRange(1, 2)),
    ])
    assert_eq(provider.get_status().effective, mode)
    let deleted = compute_with_provider(
      provider, "test \"sample\" { old_value() }\nfn stable() {}", "fn stable() {}",
    )
    assert_true(deleted.changes.is_empty())
    assert_eq(deleted.additional_alignments, [
      LineRangeMapping(LineRange(1, 2), LineRange(1, 1)),
    ])
    assert_eq(provider.get_status().effective, mode)
    provider.dispose()
  }
}

///|
test "test filtering composes with visible production changes" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let result = compute_with_provider(
      provider, "fn production() { old_value() }\nfn stable() {}", "fn production() { new_value() }\ntest \"sample\" { new_test() }\nfn stable() {}",
    )
    assert_eq(
      result.changes.map(change => (change.original, change.modified)),
      [(LineRange(1, 2), LineRange(1, 2))],
    )
    assert_eq(result.additional_alignments, [
      LineRangeMapping(LineRange(2, 2), LineRange(2, 3)),
    ])
    assert_eq(provider.get_status().effective, mode)
    provider.dispose()
  }
}

///|
test "test and comment filters remain independent" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let visible = compute_with_provider(
      provider, "fn value() { // old\n}", "fn value() { // new\n}",
    )
    assert_false(visible.changes.is_empty())
    provider.set_ignore_comments(true)
    let ignored = compute_with_provider(
      provider, "fn value() { // old\n}", "fn value() { // new\n}",
    )
    assert_true(ignored.changes.is_empty())
    provider.dispose()
  }
}

///|
test "parse failure keeps test changes visible" {
  for mode in [Token, Tree] {
    let provider = MoonDocumentDiffProvider(
      mode~,
      ignore_comments=false,
      ignore_tests=true,
    )
    let result = compute_with_provider(
      provider, "test \"sample\" { old_value( }", "test \"sample\" { new_value( }",
    )
    assert_false(result.changes.is_empty())
    assert_eq(provider.get_status(), {
      requested: mode,
      effective: Token,
      fell_back: mode is Tree,
    })
    provider.dispose()
  }
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
  assert_true(provider.get_ignore_tests())
  let object : &@diff.DocumentDiffProvider = provider
  let updates = Ref(0)
  let subscription = object.on_did_change(() => updates.val += 1)
  provider.set_mode(Token)
  provider.set_ignore_comments(false)
  provider.set_ignore_comments(false)
  provider.set_ignore_tests(false)
  provider.set_ignore_tests(false)
  assert_eq(updates.val, 3)
  subscription.dispose()
  provider.dispose()
}
