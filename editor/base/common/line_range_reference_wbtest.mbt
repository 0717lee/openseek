// Conformance port of Monaco/VS Code's LineRange / LineRangeSet suites.
//
// Ports: vscode/src/vs/editor/test/common/core/lineRange.test.ts
// From the checked-in vscode submodule.

///|
test "contains" {
  let r = LineRange(2, 3)
  assert_eq(r.contains(1), false)
  assert_eq(r.contains(2), true)
  assert_eq(r.contains(3), false)
  assert_eq(r.contains(4), false)
}

///|
test "joinMany" {
  assert_eq(LineRange::join_many([]).length(), 0)

  let first = [LineRange(2, 3), LineRange(5, 7)]
  let single = LineRange::join_many([first])
  assert_eq(single.length(), 2)
  assert_true(single[0] == LineRange(2, 3))
  assert_true(single[1] == LineRange(5, 7))
  // The source copies its first input rather than returning the caller array.
  first[0] = LineRange(100, 101)
  assert_true(single[0] == LineRange(2, 3))

  let joined_inputs : Array[Array[LineRange]] = [
    [LineRange(2, 3), LineRange(5, 7), LineRange(10, 20)],
    [LineRange(3, 4), LineRange(6, 8), LineRange(9, 11)],
    [LineRange(30, 31)],
  ]
  let joined = LineRange::join_many(joined_inputs)
  assert_eq(joined.length(), 4)
  assert_true(joined[0] == LineRange(2, 4))
  assert_true(joined[1] == LineRange(5, 8))
  assert_true(joined[2] == LineRange(9, 20))
  assert_true(joined[3] == LineRange(30, 31))
}
