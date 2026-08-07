///|
test "frontend relative paths use URI rules" {
  assert_true(
    @pathx.Relative("src/tmp/../main.mbt").normalize() ==
    Relative("src/main.mbt"),
  )
  assert_true(
    @pathx.Relative("dir\\name/./file").normalize() ==
    Relative("dir\\name/file"),
  )
  assert_true(@pathx.Relative("a/..").normalize().is_root())
}

///|
test "frontend relative containment normalizes URI paths" {
  assert_true(@pathx.Relative("src").contains(Relative("src/tmp/../a.mbt")))
  assert_false(
    @pathx.Relative("src").contains(Relative("src/tmp/../../src2/a.mbt")),
  )
}
