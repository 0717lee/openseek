///|
test "MarkerDecorations diff: no-op and add/remove" {
  let model = @model.TextModel(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="model",
      path="/diff.mbt",
    ),
    "",
    "moonbit",
    1,
    "rev",
    "hello world\nsecond line",
  )
  let md = MarkerDecorations::new(model)
  let m1 = make_marker(Error, 1, 1, 1, 3)
  let m2 = make_marker(Warning, 2, 1, 2, 5)
  // first update adds both
  assert_true(md.update([m1, m2]))
  assert_eq(md.get_markers().length(), 2)
  // identical set → diffSets no-op (load-bearing early return)
  assert_false(md.update([m1, m2]))
  // dropping m2 is a change
  assert_true(md.update([m1]))
  assert_eq(md.get_markers().length(), 1)
  let (range, marker) = md.get_markers()[0]
  assert_true(range == Range(1, 1, 1, 3))
  assert_true(marker.severity == Error)
}

///|
test "MarkerDecorations diff preserves duplicate multiplicity" {
  let model = @model.TextModel(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="model",
      path="/duplicate-diff.mbt",
    ),
    "",
    "moonbit",
    1,
    "rev",
    "hello world",
  )
  let md = MarkerDecorations::new(model)
  let first = make_marker(Error, 1, 1, 1, 3)
  let second = make_marker(Error, 1, 1, 1, 3)
  assert_true(md.update([first, second]))
  assert_eq(md.get_markers().length(), 2)

  // A fresh but structurally equal singleton matches one occurrence and
  // removes exactly the other, just as Monaco's identity-keyed map does.
  assert_true(md.update([make_marker(Error, 1, 1, 1, 3)]))
  assert_eq(md.get_markers().length(), 1)
  // Growing the duplicate multiset again adds exactly one decoration.
  assert_true(
    md.update([make_marker(Error, 1, 1, 1, 3), make_marker(Error, 1, 1, 1, 3)]),
  )
  assert_eq(md.get_markers().length(), 2)
}
