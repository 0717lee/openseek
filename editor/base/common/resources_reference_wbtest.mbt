// Conformance port of `vs/base/test/common/resources.test.ts` in the checked-in
// vscode source, suite "Resources".
// `distinctParents` covers a DEFERRED member and is not transcribed.
//
// The `isWindows` branches run under the D8 seam (both ways where the JS
// test only ran the host's); URIs are created after setting the seam
// because `fs_path`/`to_string` cache (D5). `dirname`/`isEqualOrParent`
// URI-level calls go through `ext_uri` (bound exports omitted — see
// resources.mbt header).

///|
test "compare is code-unit lexicographic, not length-first (test matrix)" {
  // MoonBit's built-in String compare would order "z" before "aa".
  assert_eq(ext_uri.compare(Uri::parse("s://x/z"), Uri::parse("s://x/aa")), 1)
  assert_eq(ext_uri.compare(Uri::parse("s://x/aa"), Uri::parse("s://x/z")), -1)
  assert_eq(ext_uri.compare(Uri::parse("s://x/a"), Uri::parse("s://x/a")), 0)
  // fragment handling
  assert_eq(
    ext_uri.compare(
      Uri::parse("s://x/a#f"),
      Uri::parse("s://x/a"),
      ignore_fragment=true,
    ),
    0,
  )
}
