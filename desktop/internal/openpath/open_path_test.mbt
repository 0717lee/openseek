// Black-box filesystem tests for the public conservative-resolution contract.

///|
async test "literal colon-number paths win before editor positions" {
  let dir = "_build/openpath-resolution-test"
  if @fs.exists(dir) {
    @fs.rmdir(dir, recursive=true)
  }
  @fs.mkdir(dir, recursive=true)
  let base = "\{dir}/source.mbt"
  let literal = "\{base}:2738"
  @fs.write_file(base, "base", create_mode=CreateOrTruncate)
  @fs.write_file(literal, "literal", create_mode=CreateOrTruncate)
  @debug.assert_eq(@openpath.Reference(literal).resolve(), SystemPath(literal))
  @fs.remove(literal)
  @debug.assert_eq(
    @openpath.Reference(literal).resolve(),
    EditorPath(path=base, line=2738, column=None),
  )
  @debug.assert_eq(
    @openpath.Reference("\{base}:2738:17").resolve(),
    EditorPath(path=base, line=2738, column=Some(17)),
  )
  let fragment = "\{base}#L5"
  @fs.write_file(fragment, "literal fragment", create_mode=CreateOrTruncate)
  @debug.assert_eq(
    @openpath.Reference(fragment).resolve(),
    SystemPath(fragment),
  )
  @fs.remove(fragment)
  @debug.assert_eq(
    @openpath.Reference(fragment).resolve(),
    EditorPath(path=base, line=5, column=None),
  )
  // Invalid or unresolved suffixes continue to surface the literal path.
  let cases = [
    "\{dir}/missing.mbt:12",
    "\{dir}/missing.mbt:12:4",
    "\{dir}/missing.mbt:0",
    "\{dir}/missing.mbt:not-a-line",
    "\{dir}/missing.mbt#L0",
    "\{dir}/ordinary.mbt",
    "\{dir}:12",
  ]
  for path in cases {
    @debug.assert_eq(@openpath.Reference(path).resolve(), SystemPath(path))
  }
}
