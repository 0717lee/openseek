///|
test "fuzzy-match ranking promotes an exact workspace symbol" {
  let backend_order = [
    test_symbol(
      "SparseArray::unsafe_get", "immut/internal/sparse_array/sparse_array.mbt",
    ),
    test_symbol(
      "UninitializedArray::unsafe_get", "builtin/uninitialized_array.mbt",
    ),
    test_symbol("Array::unsafe_get", "builtin/array.mbt"),
    test_symbol("ArrayView::unsafe_get", "builtin/arrayview.mbt"),
    test_symbol("FixedArray::unsafe_get", "builtin/intrinsics.mbt"),
  ]
  let ranked = rank_symbols("Array::unsafe_get", backend_order)
  assert_eq(ranked[0].name, "Array::unsafe_get")
  assert_eq(ranked.length(), backend_order.length())
}

///|
test "workspace symbols follow fuzzy-match score ordering" {
  let ranked = rank_symbols("abc", [
    test_symbol("___abc___", "one.mbt"),
    test_symbol("aBc", "two.mbt"),
    test_symbol("Abc_defgh", "three.mbt"),
    test_symbol("abc", "four.mbt"),
    test_symbol("foof", "five.mbt"),
  ])
  assert_eq(ranked.map(item => item.name), [
    "aBc", "abc", "Abc_defgh", "___abc___", "foof",
  ])
}

///|
test "workspace symbol ranking keeps duplicate names stable" {
  let duplicate_a = test_symbol("alpha", "z.mbt")
  let duplicate_b = test_symbol("alpha", "a.mbt")
  let ranked = rank_symbols("", [
    test_symbol("longerName", "long.mbt"),
    duplicate_a,
    duplicate_b,
    test_symbol("beta", "b.mbt"),
  ])
  assert_eq(ranked.map(item => item.name), [
    "beta", "alpha", "alpha", "longerName",
  ])
  assert_eq(ranked[1].path, "z.mbt")
  assert_eq(ranked[2].path, "a.mbt")
}
