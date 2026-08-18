///|
fn change_str(change : @diff.DetailedLineRangeMapping) -> String {
  "\{change.original.to_string()}->\{change.modified.to_string()}"
}

///|
test "compute_changes preserves the three detailed line-mapping shapes" {
  assert_eq(
    change_str(
      compute_changes(["a", "old 1", "old 2", "tail"], ["a", "new", "tail"])[0],
    ),
    "[2,4)->[2,3)",
  )
  assert_eq(
    change_str(
      compute_changes(["a", "tail"], ["a", "new 1", "new 2", "tail"])[0],
    ),
    "[2,2)->[2,4)",
  )
  assert_eq(
    change_str(
      compute_changes(["a", "old 1", "old 2", "tail"], ["a", "tail"])[0],
    ),
    "[2,4)->[2,2)",
  )
}

///|
test "compute_changes runs the full pipeline over line arrays" {
  let changes = compute_changes(["a", "old", "b", "tail"], [
    "a", "new", "b", "inserted", "tail",
  ])
  assert_eq(changes.length(), 2)
  assert_eq(change_str(changes[0]), "[2,3)->[2,3)")
  assert_eq(@quick_diff.get_change_type(changes[0]), Modify)
  assert_eq(change_str(changes[1]), "[4,4)->[4,5)")
  assert_eq(@quick_diff.get_change_type(changes[1]), Add)
}

///|
test "compute_changes honors ignore_trim_whitespace" {
  let original = ["fn x {", "  y", "}"]
  let modified = ["fn x {", "      y", "}"]
  assert_eq(compute_changes(original, modified).length(), 1)
  assert_eq(
    compute_changes(original, modified, ignore_trim_whitespace=true).length(),
    0,
  )
}
